// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}
enum GasMode {
    VOID,
    CLAIMABLE
}

interface IERC20Rebasing {
    function configure(YieldMode) external returns (uint256);

    function claim(address recipient, uint256 amount)
        external
        returns (uint256);

    function getClaimableAmount(address account)
        external
        view
        returns (uint256);
}

interface IBlastPoints {
    function configurePointsOperator(address operator) external;

    function configurePointsOperatorOnBehalf(
        address contractAddress,
        address operator
    ) external;
}

interface IBlast {
    // configure
    function configureContract(
        address contractAddress,
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    function configure(
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    // base configuration options
    function configureClaimableYield() external;

    function configureClaimableYieldOnBehalf(address contractAddress) external;

    function configureAutomaticYield() external;

    function configureAutomaticYieldOnBehalf(address contractAddress) external;

    function configureVoidYield() external;

    function configureVoidYieldOnBehalf(address contractAddress) external;

    function configureClaimableGas() external;

    function configureClaimableGasOnBehalf(address contractAddress) external;

    function configureVoidGas() external;

    function configureVoidGasOnBehalf(address contractAddress) external;

    function configureGovernor(address _governor) external;

    function configureGovernorOnBehalf(
        address _newGovernor,
        address contractAddress
    ) external;

    // claim yield
    function claimYield(
        address contractAddress,
        address recipientOfYield,
        uint256 amount
    ) external returns (uint256);

    function claimAllYield(address contractAddress, address recipientOfYield)
        external
        returns (uint256);

    // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas)
        external
        returns (uint256);

    function claimGasAtMinClaimRate(
        address contractAddress,
        address recipientOfGas,
        uint256 minClaimRateBips
    ) external returns (uint256);

    function claimMaxGas(address contractAddress, address recipientOfGas)
        external
        returns (uint256);

    function claimGas(
        address contractAddress,
        address recipientOfGas,
        uint256 gasToClaim,
        uint256 gasSecondsToConsume
    ) external returns (uint256);

    // read functions
    function readClaimableYield(address contractAddress)
        external
        view
        returns (uint256);

    function readYieldConfiguration(address contractAddress)
        external
        view
        returns (uint8);

    function readGasParams(address contractAddress)
        external
        view
        returns (
            uint256 etherSeconds,
            uint256 etherBalance,
            uint256 lastUpdated,
            GasMode
        );
}

contract WETHStakingBlastRoulette is Ownable, ReentrancyGuard, Pausable {
    IERC20 public weth;

    struct RewardData {
        uint256 amount;
        uint256 timestamp;
    }

    uint256 public totalStaked;
    mapping(address => uint256) public userStake;

    address[] public stakers;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event FundsSentToGame(address indexed gameAddress, uint256 amount);

    mapping(address => RewardData[]) public userRewards;
    mapping(address => bool) private isStaker;

    mapping(address => bool) public authorizedContracts;

    modifier onlyAuthorizedContract() {
        require(authorizedContracts[msg.sender], "Not authorized");
        _;
    }

    address public BLAST_POINTS = 0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800;
    address public USDB_ADDRESS = 0x4300000000000000000000000000000000000003;
    address public WETH_ADDRESS = 0x4300000000000000000000000000000000000004;
    address public POINTS_OPERATOR = 0xE49a44F442ff9201884716510b3B87ea70F4F16e;
    address public GAME_ADDRESS = 0x063E680575E344273b3a026880E9041935F90473;

    IBlast public constant BLAST =
        IBlast(0x4300000000000000000000000000000000000002);

    constructor() Ownable(msg.sender) {
        weth = IERC20(WETH_ADDRESS);
        authorizedContracts[GAME_ADDRESS] = true;
        IERC20Rebasing(USDB_ADDRESS).configure(YieldMode.CLAIMABLE);
        IERC20Rebasing(WETH_ADDRESS).configure(YieldMode.CLAIMABLE);

        BLAST.configureClaimableYield();
        BLAST.configureClaimableGas();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addAuthorizedContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = true;
    }

    function removeAuthorizedContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = false;
    }

    function balanceOf(address account) external view returns (uint256) {
        return userStake[account];
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Quantity must be greater than zero");

        require(
            weth.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        userStake[msg.sender] += amount;
        totalStaked += amount;

        if (!isStaker[msg.sender]) {
            stakers.push(msg.sender);
            isStaker[msg.sender] = true;
        }

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Quantity must be greater than zero");
        require(userStake[msg.sender] >= amount, "Insufficient balance");

        require(weth.transfer(msg.sender, amount), "Transfer failed");

        userStake[msg.sender] -= amount;
        totalStaked -= amount;

        emit Withdrawn(msg.sender, amount);
    }

    function distributeRewards(uint256 amount)
        external
        nonReentrant
        onlyAuthorizedContract
    {
        require(amount > 0, "Quantity must be greater than zero");
        require(totalStaked > 0, "staked");

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 stakeAmount = userStake[staker];
            uint256 reward = (stakeAmount * amount) / totalStaked;
            userStake[staker] += reward;
            userRewards[staker].push(
                RewardData({amount: reward, timestamp: block.timestamp})
            );
        }

        totalStaked += amount;
    }

    function deductRewards(uint256 amount)
        external
        nonReentrant
        onlyAuthorizedContract
    {
        require(amount > 0, "Quantity must be greater than zero");
        require(totalStaked > 0, "staked");

        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            uint256 stakeAmount = userStake[staker];
            uint256 reward = (stakeAmount * amount) / totalStaked;
            userStake[staker] -= reward;
            userRewards[staker].push(
                RewardData({amount: reward, timestamp: block.timestamp})
            );
        }
        totalStaked -= amount;
    }

    function sendToGame(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");
        require(weth.transfer(GAME_ADDRESS, amount), "Transfer failed");
        emit FundsSentToGame(GAME_ADDRESS, amount);
    }

    function getUserRewards(address staker)
        external
        view
        returns (RewardData[] memory)
    {
        return userRewards[staker];
    }

    function claimAllGas() external nonReentrant onlyOwner {
        BLAST.claimAllGas(address(this), msg.sender);
    }

    function claimYieldTokens(address _recipient, uint256 _amount)
        external
        nonReentrant
        onlyOwner
        returns (uint256, uint256)
    {
        return (
            IERC20Rebasing(USDB_ADDRESS).claim(_recipient, _amount),
            IERC20Rebasing(WETH_ADDRESS).claim(_recipient, _amount)
        );
    }

    function getClaimableAmount(address _account)
        external
        view
        returns (uint256, uint256)
    {
        return (
            IERC20Rebasing(USDB_ADDRESS).getClaimableAmount(_account),
            IERC20Rebasing(WETH_ADDRESS).getClaimableAmount(_account)
        );
    }

    function updatePointsOperator(address _newOperator) external onlyOwner {
        IBlastPoints(POINTS_OPERATOR).configurePointsOperatorOnBehalf(
            address(this),
            _newOperator
        );
    }

    function configureVoidYield() external onlyOwner {
        BLAST.configureVoidYield();
    }

    function configureVoidYieldOnBehalf() external onlyOwner {
        BLAST.configureVoidYieldOnBehalf(address(this));
    }

    function configureClaimableGasOnBehalf() external onlyOwner {
        BLAST.configureClaimableGasOnBehalf(address(this));
    }

    function configureVoidGas() external onlyOwner {
        BLAST.configureVoidGas();
    }

    function configureVoidGasOnBehalf() external onlyOwner {
        BLAST.configureVoidGasOnBehalf(address(this));
    }

    function claimYield(address recipient, uint256 amount) external onlyOwner {
        BLAST.claimYield(address(this), recipient, amount);
    }

    function claimAllYield(address recipient) external onlyOwner {
        BLAST.claimAllYield(address(this), recipient);
    }

    function claimGasAtMinClaimRate(
        address recipientOfGas,
        uint256 minClaimRateBips
    ) external onlyOwner {
        BLAST.claimGasAtMinClaimRate(
            address(this),
            recipientOfGas,
            minClaimRateBips
        );
    }

    function claimMaxGas(address recipientOfGas) external onlyOwner {
        BLAST.claimMaxGas(address(this), recipientOfGas);
    }

    function claimGas(
        address recipientOfGas,
        uint256 gasToClaim,
        uint256 gasSecondsToConsume
    ) external onlyOwner {
        BLAST.claimGas(
            address(this),
            recipientOfGas,
            gasToClaim,
            gasSecondsToConsume
        );
    }

    function readClaimableYield() external view returns (uint256) {
        return BLAST.readClaimableYield(address(this));
    }

    function readYieldConfiguration() external view returns (uint8) {
        return BLAST.readYieldConfiguration(address(this));
    }

    function readGasParams()
        external
        view
        returns (
            uint256 etherSeconds,
            uint256 etherBalance,
            uint256 lastUpdated,
            GasMode
        )
    {
        return BLAST.readGasParams(address(this));
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        require(tokenAddress != address(this), "Cannot recover own tokens");
        IERC20(tokenAddress).transfer(GAME_ADDRESS, tokenAmount);
    }

    function recoverETH() external onlyOwner {
        payable(GAME_ADDRESS).transfer(address(this).balance);
    }
}
