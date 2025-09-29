// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Corn.sol";
import "./CornDEX.sol";

error Lending__InvalidAmount();
error Lending__TransferFailed();
error Lending__UnsafePositionRatio();
error Lending__BorrowingFailed();
error Lending__RepayingFailed();
error Lending__PositionSafe();
error Lending__NotLiquidatable();
error Lending__InsufficientLiquidatorCorn();

contract Lending is Ownable {
    uint256 private constant COLLATERAL_RATIO = 200; // 200% collateralization required (adjusted to match test scenario)
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators

    Corn private i_corn;
    CornDEX private i_cornDEX;

    mapping(address => uint256) public s_userCollateral; // User's collateral balance
    mapping(address => uint256) public s_userBorrowed; // User's borrowed corn balance

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed user, uint256 indexed amount, uint256 price);
    event AssetBorrowed(address indexed user, uint256 indexed amount, uint256 price);
    event AssetRepaid(address indexed user, uint256 indexed amount, uint256 price);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    constructor(address _cornDEX, address _corn) Ownable(msg.sender) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_corn.approve(address(this), type(uint256).max);
    }

    /**
     * @notice Allows users to add collateral to their account
     */
    function addCollateral() public payable {
        if (msg.value == 0) {
            revert Lending__InvalidAmount(); // Revert if no collateral is sent
        }
        s_userCollateral[msg.sender] += msg.value; // Update user's collateral balance
        emit CollateralAdded(msg.sender, msg.value, i_cornDEX.currentPrice()); // Emit event for collateral addition
    }

    /**
     * @notice Allows users to withdraw collateral as long as it doesn't make them liquidatable
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) public {
        if (amount == 0 || s_userCollateral[msg.sender] < amount) {
            revert Lending__InvalidAmount(); // Revert if the amount is invalid
        }

        // Reduce the user's collateral
        uint256 newCollateral = s_userCollateral[msg.sender] - amount;
        s_userCollateral[msg.sender] = newCollateral;

        // prevent withdrawing into unsafe state, but only if the user has outstanding debt
        if (s_userBorrowed[msg.sender] > 0) {
            _validatePosition(msg.sender);
        }

        // Transfer the collateral to the user
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert Lending__TransferFailed();
        }

        emit CollateralWithdrawn(msg.sender, amount, i_cornDEX.currentPrice()); // Emit event for collateral withdrawal
    }

    /**
     * @notice Calculates the total collateral value for a user based on their collateral balance
     * @param user The address of the user to calculate the collateral value for
     * @return uint256 The collateral value
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        uint256 collateralAmount = s_userCollateral[user]; // Get user's collateral amount
        return (collateralAmount * i_cornDEX.currentPrice()) / 1e18; // Calculate collateral value in CORN
    }

    /**
     * @notice Calculates the position ratio for a user to ensure they are within safe limits
     * @param user The address of the user to calculate the position ratio for
     * @return uint256 The position ratio
     */
    function _calculatePositionRatio(address user) internal view returns (uint256) {
        uint borrowedAmount = s_userBorrowed[user]; // Get user's borrowed amount
        uint collateralValue = calculateCollateralValue(user); // Calculate user's collateral value
        if (borrowedAmount == 0) return type(uint256).max; // Return max if no corn is borrowed
        // collateralValue and borrowedAmount are in CORN-wei units
        // position ratio as percent * 1e18 = (collateralValue * 100 * 1e18) / borrowedAmount
        return (collateralValue * 100 * 1e18) / borrowedAmount;
    }

    /**
     * @notice Checks if a user's position can be liquidated
     * @param user The address of the user to check
     * @return bool True if the position is liquidatable, false otherwise
     */
    function isLiquidatable(address user) public view returns (bool) {
        uint256 positionRatio = _calculatePositionRatio(user); // Calculate user's position ratio
        return positionRatio < COLLATERAL_RATIO * 1e18; // Check if position is unsafe
    }

    /**
     * @notice Internal view method that reverts if a user's position is unsafe
     * @param user The address of the user to validate
     */
    function _validatePosition(address user) internal view {
        if (isLiquidatable(user)) {
            revert Lending__UnsafePositionRatio();
        }
    }

    /**
     * @notice Allows users to borrow corn based on their collateral
     * @param borrowAmount The amount of corn to borrow
     */
    function borrowCorn(uint256 borrowAmount) public {
        if (borrowAmount == 0) {
            revert Lending__InvalidAmount();
        }

        // Update borrowed amount first
        s_userBorrowed[msg.sender] += borrowAmount;

        // Validate new position using helper
        _validatePosition(msg.sender);

        // Transfer CORN to user
        bool success = i_corn.transfer(msg.sender, borrowAmount);
        if (!success) {
            revert Lending__BorrowingFailed();
        }

        emit AssetBorrowed(msg.sender, borrowAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to repay corn and reduce their debt
     * @param repayAmount The amount of corn to repay
     */
    function repayCorn(uint256 repayAmount) public {
        if (repayAmount == 0) {
            revert Lending__InvalidAmount();
        }

        uint256 currentBorrowed = s_userBorrowed[msg.sender];
        if (repayAmount > currentBorrowed) {
            revert Lending__InvalidAmount();
        }

        // Update borrowed amount first
        s_userBorrowed[msg.sender] = currentBorrowed - repayAmount;

        // Transfer CORN from user to contract
        bool success = i_corn.transferFrom(msg.sender, address(this), repayAmount);
        if (!success) {
            revert Lending__RepayingFailed();
        }

        emit AssetRepaid(msg.sender, repayAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows liquidators to liquidate unsafe positions
     * @param user The address of the user to liquidate
     * @dev The caller must have enough CORN to pay back user's debt
     * @dev The caller must have approved this contract to transfer the debt
     */
    function liquidate(address user) public {
        if (!isLiquidatable(user)) {
            revert Lending__NotLiquidatable(); // Revert if position is not liquidatable
        }

        uint256 userDebt = s_userBorrowed[user]; // Get user's borrowed amount

        // Ensure liquidator has enough CORN to repay the debt
        if (i_corn.balanceOf(msg.sender) < userDebt) {
            revert Lending__InsufficientLiquidatorCorn();
        }

        uint256 userCollateral = s_userCollateral[user]; // Get user's collateral balance
        uint256 collateralValue = calculateCollateralValue(user); // Calculate user's collateral value

        // transfer value of debt to the contract
        bool ok = i_corn.transferFrom(msg.sender, address(this), userDebt);
        if (!ok) {
            revert Lending__BorrowingFailed();
        }

        // Clear user's debt
        s_userBorrowed[user] = 0;

        // calculate collateral to purchase (maintain the ratio of debt to collateral value)
        uint256 collateralPurchased = 0;
        if (collateralValue > 0) {
            collateralPurchased = (userDebt * userCollateral) / collateralValue;
        }
        uint256 liquidatorReward = (collateralPurchased * LIQUIDATOR_REWARD) / 100;
        uint256 amountForLiquidator = collateralPurchased + liquidatorReward;
        // Ensure we don't exceed user's collateral
        if (amountForLiquidator > userCollateral) {
            amountForLiquidator = userCollateral;
        }

        s_userCollateral[user] = userCollateral - amountForLiquidator;

        // transfer collateral (ETH) to the liquidator
        (bool success, ) = payable(msg.sender).call{ value: amountForLiquidator }("");
        if (!success) {
            revert Lending__TransferFailed();
        }

        emit Liquidation(user, msg.sender, amountForLiquidator, userDebt, i_cornDEX.currentPrice());
    }

    // Debug helper to inspect values during testing
    function getDebugInfo(address user)
        public
        view
        returns (uint256 collateralValue, uint256 borrowed, uint256 positionRatio, uint256 price, uint256 collateralAmount)
    {
        collateralAmount = s_userCollateral[user];
        collateralValue = calculateCollateralValue(user);
        borrowed = s_userBorrowed[user];
        price = i_cornDEX.currentPrice();
        positionRatio = borrowed == 0 ? type(uint256).max : (collateralValue * 100 * 1e18) / borrowed;
    }
}
