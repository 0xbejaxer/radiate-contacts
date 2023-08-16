// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
pragma abicoder v2;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

import {Kernel, Keycode, Permissions, toKeycode, Policy} from "../Kernel.sol";
import {RolesConsumer, ROLESv1} from "../modules/ROLES/OlympusRoles.sol";

import {IDLPVault} from "../interfaces/radiate/IDLPVault.sol";
import {IAToken} from "../interfaces/radiant-interfaces/IAToken.sol";
import {ILendingPool, DataTypes} from "../interfaces/radiant-interfaces/ILendingPool.sol";
import {IVariableDebtToken} from "../interfaces/radiant-interfaces/IVariableDebtToken.sol";
import {IChefIncentivesController} from "../interfaces/radiant-interfaces/IChefIncentivesController.sol";
import {IMultiFeeDistribution} from "../interfaces/radiant-interfaces/IMultiFeeDistribution.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/aave/IFlashLoanSimpleReceiver.sol";

contract Leverager is
    ReentrancyGuardUpgradeable,
    RolesConsumer,
    IFlashLoanSimpleReceiver
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    //============================================================================================//
    //                                         CONSTANT                                           //
    //============================================================================================//

    /// @notice Lending Pool address
    ILendingPool public constant LENDING_POOL =
        ILendingPool(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);

    /// @notice Chef Incentives Controller
    IChefIncentivesController public constant CHEF_INCENTIVES_CONTROLLER =
        IChefIncentivesController(0xebC85d44cefb1293707b11f707bd3CEc34B4D5fA);

    /// @notice Multi Fee Distributor
    IMultiFeeDistribution public constant MFD =
        IMultiFeeDistribution(0x76ba3eC5f5adBf1C58c91e86502232317EeA72dE);

    /// @notice Aave lending pool address (for flashloans)
    IPool public constant AAVE_LENDING_POOL =
        IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    /// @notice Multiplier 100%
    uint256 public constant MULTIPLIER = 1e6;

    /// @notice Precision
    uint256 public constant PRECISION = 1e20;

    uint256 internal constant _RAY = 1e27;
    uint256 internal constant _HALF_RAY = _RAY / 2;

    //============================================================================================//
    //                                          STORAGE                                           //
    //============================================================================================//

    /// @notice kernel
    Kernel public kernel;

    /// @notice Dlp vault contract
    IDLPVault public dlpVault;

    /// @notice Staking token
    IERC20 public asset;

    /// @notice Borrow ratio
    uint256 public borrowRatio;

    /// @notice Acc token per share
    uint256 public accTokenPerShare;

    /// @notice Total scaled balance of aToken
    uint256 public totalSB;

    /// @notice Stake info
    struct Stake {
        uint256 aTSB; // aToken's scaled balance
        uint256 dTSB; // debtToken's scaled balance
        uint256 pending;
        uint256 debt;
    }
    mapping(address => Stake) public stakeInfo;

    /// @notice Claim info
    struct Claim {
        uint256 amount;
        address receiver;
        bool isClaimed;
        uint32 expireAt;
    }
    uint256 public claimIndex;
    mapping(uint256 => Claim) public claimInfo;
    mapping(address => EnumerableSet.UintSet) private _userClaims;

    //============================================================================================//
    //                                           EVENT                                            //
    //============================================================================================//

    event KernelChanged(address kernel);
    event BorrowRatioUpdated(uint256 borrowRatio);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(
        address indexed account,
        uint256 indexed index,
        uint256 amount,
        uint32 expireAt
    );
    event ClaimedVested(
        address indexed account,
        uint256 indexed index,
        uint256 amount
    );

    //============================================================================================//
    //                                           ERROR                                            //
    //============================================================================================//

    error CALLER_NOT_KERNEL();
    error CALLER_NOT_AAVE();
    error MATH_MULTIPLICATION_OVERFLOW();
    error INVALID_AMOUNT();
    error INVALID_UNSTAKE();
    error INVALID_CLAIM();
    error ERROR_BORROW_RATIO(uint256 borrowRatio);

    //============================================================================================//
    //                                         INITIALIZE                                         //
    //============================================================================================//

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        Kernel _kernel,
        IDLPVault _dlpVault,
        IERC20 _asset,
        uint256 _borrowRatio
    ) external initializer {
        if (_borrowRatio >= MULTIPLIER) revert ERROR_BORROW_RATIO(_borrowRatio);

        kernel = _kernel;
        dlpVault = _dlpVault;
        asset = _asset;
        borrowRatio = _borrowRatio;

        _asset.safeApprove(address(LENDING_POOL), type(uint256).max);
        _asset.safeApprove(address(AAVE_LENDING_POOL), type(uint256).max);

        __ReentrancyGuard_init();
    }

    //============================================================================================//
    //                                          MODIFIER                                          //
    //============================================================================================//

    modifier onlyKernel() {
        if (msg.sender != address(kernel)) revert CALLER_NOT_KERNEL();

        _;
    }

    modifier onlyAaveLendingPool() {
        if (msg.sender != address(AAVE_LENDING_POOL)) revert CALLER_NOT_AAVE();

        _;
    }

    modifier onlyAdmin() {
        ROLES.requireRole("admin", msg.sender);

        _;
    }

    //============================================================================================//
    //                                     DEFAULT OVERRIDES                                      //
    //============================================================================================//

    function changeKernel(Kernel _kernel) external onlyKernel {
        kernel = _kernel;

        emit KernelChanged(address(_kernel));
    }

    function isActive() external view returns (bool) {
        return kernel.isPolicyActive(Policy(address(this)));
    }

    function configureDependencies()
        external
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("ROLES");
        ROLES = ROLESv1(address(kernel.getModuleForKeycode(dependencies[0])));
    }

    function requestPermissions()
        external
        pure
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](0);
    }

    //============================================================================================//
    //                                         ADMIN                                              //
    //============================================================================================//

    function recoverERC20(
        IERC20 _token,
        uint256 _tokenAmount
    ) external onlyAdmin {
        _token.safeTransfer(msg.sender, _tokenAmount);
    }

    //============================================================================================//
    //                                     LENDING LOGIC                                          //
    //============================================================================================//

    /**
     * @dev Returns the configuration of the reserve
     * @return The configuration of the reserve
     *
     */
    function getConfiguration()
        public
        view
        returns (DataTypes.ReserveConfigurationMap memory)
    {
        return LENDING_POOL.getConfiguration(address(asset));
    }

    /**
     * @dev Returns variable debt token address of asset
     * @return varaiableDebtToken address of the asset
     *
     */
    function getVDebtToken() public view returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            address(asset)
        );
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @dev Returns atoken address of asset
     * @return varaiableDebtToken address of the asset
     *
     */
    function getAToken() public view returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            address(asset)
        );
        return reserveData.aTokenAddress;
    }

    /**
     * @dev Returns loan to value
     * @return ltv of the asset
     *
     */
    function ltv() public view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory conf = LENDING_POOL
            .getConfiguration(address(asset));
        return conf.data % (2 ** 16);
    }

    /**
     * @dev Divides two ray, rounding half up to the nearest ray
     * @param a Ray
     * @param b Ray
     * @return The result of a/b, in ray
     **/
    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }

        if (a > (type(uint256).max - _HALF_RAY) / b)
            revert MATH_MULTIPLICATION_OVERFLOW();

        return (a * b + _HALF_RAY) / _RAY;
    }

    //============================================================================================//
    //                                     REWARDS LOGIC                                          //
    //============================================================================================//

    function _update() internal {
        if (totalSB == 0) return;

        // claim reward
        uint256 reward;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = getAToken();
            tokens[1] = getVDebtToken();
            uint256[] memory rewards = CHEF_INCENTIVES_CONTROLLER
                .pendingRewards(address(dlpVault), tokens);
            uint256 length = rewards.length;

            for (uint256 i = 0; i < length; ) {
                unchecked {
                    reward += rewards[i];
                    ++i;
                }
            }

            if (reward == 0) return;

            CHEF_INCENTIVES_CONTROLLER.claim(address(dlpVault), tokens);
        }

        // update rate
        accTokenPerShare += (reward * PRECISION) / totalSB;
    }

    function _updatePending(address _account) internal {
        Stake storage info = stakeInfo[_account];

        info.pending = (accTokenPerShare * info.aTSB) / PRECISION - info.debt;
    }

    function _updateDebt(address _account) internal {
        Stake storage info = stakeInfo[_account];

        info.debt = (accTokenPerShare * info.aTSB) / PRECISION;
    }

    //============================================================================================//
    //                                     LOOPING LOGIC                                          //
    //============================================================================================//

    /**
     * @dev Loop the deposit and borrow of an asset (removed eth loop, deposit WETH directly)
     *
     */
    function _loop(uint256 amount) internal {
        if (amount == 0) return;

        IAToken aToken = IAToken(getAToken());
        IVariableDebtToken debtToken = IVariableDebtToken(getVDebtToken());

        uint256 aTSBBefore = aToken.scaledBalanceOf(address(dlpVault));
        uint256 dTSBBefore = debtToken.scaledBalanceOf(address(dlpVault));

        // deposit
        LENDING_POOL.deposit(address(asset), amount, address(dlpVault), 0);

        // flashloan for loop
        uint256 loanAmount = (amount * borrowRatio) /
            (MULTIPLIER - borrowRatio);
        if (loanAmount == 0) return;

        AAVE_LENDING_POOL.flashLoanSimple(
            address(this),
            address(asset),
            loanAmount,
            "",
            0
        );

        // stake info
        Stake storage info = stakeInfo[msg.sender];
        info.aTSB += aToken.scaledBalanceOf(address(dlpVault)) - aTSBBefore;
        info.dTSB += debtToken.scaledBalanceOf(address(dlpVault)) - dTSBBefore;

        totalSB += aToken.scaledBalanceOf(address(dlpVault)) - aTSBBefore;
    }

    /**
     * @dev Loop the deposit and borrow of an asset to repay flashloan
     *
     */
    function executeOperation(
        address _asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external override onlyAaveLendingPool returns (bool) {
        require(initiator == address(this));

        // deposit
        LENDING_POOL.deposit(_asset, amount, address(dlpVault), 0);

        // borrow for repay
        uint256 borrowAmount = amount + premium; // repay
        uint256 interestRateMode = 2; // variable
        LENDING_POOL.borrow(
            _asset,
            borrowAmount,
            interestRateMode,
            0,
            address(dlpVault)
        );

        return true;
    }

    //============================================================================================//
    //                                         STAKE LOGIC                                        //
    //============================================================================================//

    function staked(
        address _account
    ) public view returns (uint256 aTokenAmount, uint256 debtTokenAmount) {
        Stake storage info = stakeInfo[_account];

        aTokenAmount = _rayMul(
            info.aTSB,
            LENDING_POOL.getReserveNormalizedIncome(address(asset))
        );
        debtTokenAmount = _rayMul(
            info.dTSB,
            LENDING_POOL.getReserveNormalizedVariableDebt(address(asset))
        );
    }

    function stake(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert INVALID_AMOUNT();

        _update();
        _updatePending(msg.sender);

        asset.safeTransferFrom(msg.sender, address(this), _amount);
        _loop(_amount);

        _updateDebt(msg.sender);

        emit Staked(msg.sender, _amount);
    }

    function unstakeable(address _account) public view returns (uint256) {
        (uint256 aTokenAmount, uint256 debtTokenAmount) = staked(_account);

        if (aTokenAmount > debtTokenAmount) return 0;

        return aTokenAmount - debtTokenAmount;
    }

    function unstake(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert INVALID_AMOUNT();

        uint256 unstakeableAmount = unstakeable(msg.sender);
        if (_amount > unstakeableAmount) revert INVALID_UNSTAKE();

        Stake storage info = stakeInfo[msg.sender];
        uint256 repayAmount = (info.dTSB * _amount) / unstakeableAmount;

        // flashloan for unloop
        AAVE_LENDING_POOL.flashLoanSimple(
            address(dlpVault),
            address(asset),
            repayAmount,
            abi.encode(_amount, msg.sender),
            0
        );

        info.aTSB -= _amount + repayAmount;
        info.dTSB -= repayAmount;
        _updateDebt(msg.sender);

        emit Unstaked(msg.sender, _amount);
    }

    function claimable(
        address _account
    ) external view returns (uint256 pending, uint256 expireAt) {
        uint256 reward;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = getAToken();
            tokens[1] = getVDebtToken();
            uint256[] memory rewards = CHEF_INCENTIVES_CONTROLLER
                .pendingRewards(address(dlpVault), tokens);
            uint256 length = rewards.length;

            for (uint256 i = 0; i < length; ) {
                unchecked {
                    reward += rewards[i];
                    ++i;
                }
            }
        }

        uint256 _accTokenPerShare = accTokenPerShare +
            (reward * PRECISION) /
            totalSB;
        Stake memory info = stakeInfo[_account];

        pending =
            info.pending +
            (_accTokenPerShare * info.aTSB) /
            PRECISION -
            info.debt;
        expireAt = block.timestamp + MFD.vestDuration();
    }

    function claim() external nonReentrant {
        _update();
        _updatePending(msg.sender);
        _updateDebt(msg.sender);

        Stake storage info = stakeInfo[msg.sender];
        uint256 pending = info.pending;

        if (pending > 0) {
            info.pending = 0;

            uint256 index = ++claimIndex;
            uint32 expireAt = uint32(block.timestamp + MFD.vestDuration());

            Claim storage _info = claimInfo[index];
            _info.amount = pending;
            _info.receiver = msg.sender;
            _info.expireAt = expireAt;

            _userClaims[msg.sender].add(index);

            emit Claimed(msg.sender, index, pending, expireAt);
        }
    }

    function claimed(
        address _account
    ) external view returns (Claim[] memory info) {
        EnumerableSet.UintSet storage claims = _userClaims[_account];
        uint256 length = claims.length();

        info = new Claim[](length);

        for (uint256 i = 0; i < length; ) {
            info[i] = claimInfo[claims.at(i)];
            unchecked {
                ++i;
            }
        }
    }

    function claimVested(uint256 _index) external nonReentrant {
        Claim storage info = claimInfo[_index];
        if (
            info.amount == 0 ||
            info.isClaimed ||
            info.expireAt >= block.timestamp ||
            !_userClaims[info.receiver].remove(_index)
        ) revert INVALID_CLAIM();

        info.isClaimed = true;
        dlpVault.withdrawForLeverager(info.receiver, info.amount);

        emit ClaimedVested(info.receiver, _index, info.amount);
    }
}
