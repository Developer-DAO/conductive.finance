//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

/// @security development only
/// @security contact:@parseb

import "OpenZeppelin/openzeppelin-contracts@4.4.2/contracts/access/Ownable.sol";
import "OpenZeppelin/openzeppelin-contracts@4.4.2/contracts/interfaces/IERC20.sol";
import "OpenZeppelin/openzeppelin-contracts@4.4.2/contracts/security/ReentrancyGuard.sol";
import "OpenZeppelin/openzeppelin-contracts@4.4.2/contracts/token/ERC721/ERC721.sol";
import "./yInterfaces.sol";
import "./UniswapInterfaces.sol";

//import "./Station.sol";

contract Ymarkt is Ownable, ReentrancyGuard, ERC721("Train", "Train") {
    /// @dev Uniswap V3 Factory address used to validate token pair and price

    IUniswapV2Factory uniswapV2;
    IV2Registry yRegistry;

    uint256 clicker;

    Ticket[] public allTickets;
    Train[] public allTrains;
    Ticket[] blanks;

    mapping(address => Ticket[]) public offBoardingQueue;

    struct operators {
        address buybackToken; //buyback token contract address
        address denominatorToken; //quote token contract address
        address uniPool; //address of the uniswap pool ^
    }

    struct configdata {
        uint64[4] cycleParams; // [cycleFreq, minDistance, budgetSlicer, -blank 0-]
        uint32 minBagSize; // min bag size
        bool controlledSpeed; // if true, facilitate speed management
    }

    struct Train {
        operators meta;
        uint256 yieldSharesTotal; //increments on cycle, decrements on offboard
        uint256 budget; //total disposable budget
        uint256 inCustody; //total bag volume
        uint64 passengers; //unique participants/positions
        configdata config; //configdata
    }

    struct Ticket {
        uint128 destination; //promises to travel to block
        uint128 departure; // created on block
        uint256 bagSize; //amount token
        uint256 perUnit; //buyout price
        address trainAddress; //train ID (pair pool)
        uint256 nftid; //nft id
    }

    struct stationData {
        uint256 at;
        uint256 price;
        uint256 ownedQty;
    }

    /// @notice last station data
    mapping(address => stationData) public lastStation;

    /// @notice tickets fetchable by perunit price
    mapping(address => mapping(uint256 => Ticket[])) ticketsFromPrice;

    /// @notice gets Ticket of [user] for [train]
    mapping(address => mapping(address => Ticket)) userTrainTicket;

    /// @notice get Train by address
    mapping(address => Train) getTrainByPool;

    /// @notice fetch ticket from nftid [account,trainId]
    mapping(uint256 => address[2]) ticketByNftId;

    /// @notice stores train owner
    mapping(address => address) isTrainOwner;

    /// @notice stores after what block conductor will be able to withdraw howmuch of buybacked token
    mapping(address => uint64[2]) allowConductorWithdrawal; //[block, howmuch]

    mapping(address => IVault) trainAddressVault;

    constructor() {
        uniswapV2 = IUniswapV2Factory(
            0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f
        );
        yRegistry = IV2Registry(0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804);
        //yVault = IVault(0x9C13e225AE007731caA49Fd17A41379ab1a489F4);
        //yRegistry = "0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804"
        clicker = 1;
    }

    receive() external payable {
        revert();
    }

    ////////////////

    function updateEnvironment(address _poolFactory, address _vRegistry)
        public
        onlyOwner
    {
        require(_poolFactory != address(0) && _vRegistry != address(0));

        uniswapV2 = IUniswapV2Factory(_poolFactory);
        yRegistry = IV2Registry(_vRegistry);

        emit RailNetworkChanged(address(uniswapV2), _poolFactory);
    }

    ////////////////////////////////
    ///////  ERRORS

    error AlreadyOnThisTrain(address train);
    error NotOnThisTrain(address train);
    error ZeroValuesNotAllowed();
    error TrainNotFound(address ghostTrain);
    error IssueOnDeposit(uint256 amount, address token);
    error MinDepositRequired(uint256 required, uint256 provided);
    error NotTrainOwnerError(address _train, address _perp);

    //////  Errors
    ////////////////////////////////

    ////////////////////////////////
    ///////  EVENTS

    event FallbackCall(address _sender, bytes _data);

    event TrainCreated(
        address indexed _trainAddress,
        address indexed _buybackToken
    );

    event TicketCreated(
        address _passanger,
        address indexed _trainAddress,
        uint256 indexed _perUnit
    );

    event TicketBurned(
        address indexed _passanger,
        address indexed _trainAddress,
        uint256 _nftid
    );

    event TrainInStation(address indexed _trainAddress, uint256 _nrstation);

    event JumpedOut(
        address indexed _who,
        address indexed _ofTrain,
        uint256 indexed _nftID
    );

    event TrainConductorBeingWeird(
        uint256 quantity,
        address indexed train,
        address indexed conductor
    );

    event TrainConductorWithdrawal(
        address buybackToken,
        address trainAddress,
        uint256 quantity
    );

    event RailNetworkChanged(address indexed _from, address indexed _to);

    event TrainParamsChanged(
        address indexed _trainAddress,
        uint64[4] _newParams
    );
    //////  Events
    ////////////////////////////////

    //////XXXXX ERC721
    /////XXXXX  deposit at cycle in pool.

    ////////////////////////////////
    ////////  MODIFIERS

    modifier ensureTrain(address _train) {
        if (getTrainByPool[_train].meta.uniPool == address(0)) {
            revert TrainNotFound(_train);
        }
        _;
    }

    modifier ensureBagSize(uint256 _bagSize, address _train) {
        if (_bagSize < getTrainByPool[_train].config.minBagSize)
            revert MinDepositRequired(
                getTrainByPool[_train].config.minBagSize,
                _bagSize
            );
        _;
    }

    /// @dev ensure offboarding nulls ticket / destination
    modifier onlyUnticketed(address _train) {
        if (userTrainTicket[msg.sender][_train].destination > 0)
            revert AlreadyOnThisTrain(_train);
        _;
    }

    modifier onlyTicketed(address _train) {
        if (userTrainTicket[msg.sender][_train].destination == 0)
            revert NotOnThisTrain(_train);
        _;
    }

    modifier onlyExpiredTickets(address _train) {
        require(
            userTrainTicket[msg.sender][_train].destination < block.number,
            "Train is Moving"
        );
        _;
    }

    modifier zeroNotAllowed(uint64[4] memory _params) {
        for (uint8 i = 0; i < 4; i++) {
            if (_params[i] < 1) revert ZeroValuesNotAllowed();
        }
        _;
    }

    modifier onlyTrainOnwer(address _train) {
        if (!(isTrainOwner[_train] == msg.sender))
            revert NotTrainOwnerError(_train, msg.sender);
        _;
    }

    function changeTrainParams(
        address _trainAddress,
        uint64[4] memory _newparams
    )
        public
        onlyTrainOnwer(_trainAddress)
        zeroNotAllowed(_newparams)
        returns (bool)
    {
        Train memory train = getTrainByPool[_trainAddress];

        if (train.config.controlledSpeed) {
            train.config.cycleParams = _newparams;
            getTrainByPool[_trainAddress] = train;

            emit TrainParamsChanged(_trainAddress, _newparams);
            return true;
        } else {
            revert("Immutable Train");
        }
    }

    ///////   Modifiers
    /////////////////////////////////

    /////////////////////////////////
    ////////  PUBLIC FUNCTIONS

    function createTrain(
        address _buybackToken,
        address _budgetToken,
        uint64[4] memory _cycleParams,
        uint32 _minBagSize,
        bool _levers
    ) public zeroNotAllowed(_cycleParams) returns (bool successCreated) {
        address uniPool = isValidPool(_buybackToken, _budgetToken);

        if (uniPool == address(0)) {
            uniPool = uniswapV2.createPair(_buybackToken, _budgetToken);
        }

        require(uniPool != address(0));
        trainAddressVault[uniPool] = IVault(tokenHasVault(_buybackToken));

        Train memory _train = Train({
            meta: operators({
                denominatorToken: _budgetToken,
                buybackToken: _buybackToken,
                uniPool: uniPool
            }),
            yieldSharesTotal: 0,
            passengers: 0,
            budget: 0,
            inCustody: 0,
            config: configdata({
                cycleParams: _cycleParams,
                minBagSize: _minBagSize,
                controlledSpeed: _levers
            })
        });

        getTrainByPool[uniPool] = _train;
        isTrainOwner[uniPool] = msg.sender;
        allTrains.push(_train);
        emit TrainCreated(uniPool, _buybackToken);
        successCreated = true;
    }

    function createTicket(
        uint64 _stations, // how many cycles
        uint256 _perUnit, // target price
        address _trainAddress, // train address
        uint256 _bagSize // nr of tokens
    )
        public
        payable
        ensureTrain(_trainAddress)
        ensureBagSize(_bagSize, _trainAddress)
        onlyUnticketed(_trainAddress)
        nonReentrant
        returns (bool success)
    {
        if (
            _stations == 0 ||
            _bagSize == 0 ||
            _perUnit == 0 ||
            _trainAddress == address(0)
        ) {
            revert ZeroValuesNotAllowed();
        }
        require(!isInStation(_trainAddress), "please wait");
        Train memory train = getTrainByPool[_trainAddress];

        IERC20 token = IERC20(train.meta.buybackToken);
        bool transfer = token.transferFrom(msg.sender, address(this), _bagSize);
        if (!transfer) revert IssueOnDeposit(_bagSize, address(token));

        uint64 _departure = uint64(block.number);
        uint64 _destination = (_stations * train.config.cycleParams[0]) +
            _departure;

        Ticket memory ticket = Ticket({
            destination: _destination,
            departure: _departure,
            bagSize: _bagSize,
            perUnit: _perUnit,
            trainAddress: _trainAddress,
            nftid: clicker
        });

        _safeMint(msg.sender, clicker);

        userTrainTicket[msg.sender][_trainAddress] = ticket;
        ticketByNftId[clicker] = [msg.sender, _trainAddress];
        allTickets.push(ticket);
        incrementPassengers(_trainAddress);
        incrementBag(_trainAddress, _bagSize);
        incrementShares(_trainAddress, (_destination - _departure), _bagSize);

        ticketsFromPrice[_trainAddress][_perUnit].push(ticket);
        clicker++;

        success = true;
        emit TicketCreated(msg.sender, _trainAddress, _perUnit);
    }

    function burnTicket(address _train)
        public
        onlyTicketed(_train)
        nonReentrant
        returns (bool success)
    {
        require(!isInStation(_train), "please wait");
        Ticket memory ticket = userTrainTicket[msg.sender][_train];
        require(ticket.bagSize > 0, "Already Burned");

        Train memory train = getTrainByPool[ticket.trainAddress];

        success = tokenOut(train.meta.buybackToken, ticket.bagSize, _train);
        if (success) {
            _burn(ticket.nftid);
            emit JumpedOut(msg.sender, _train, ticket.nftid);
        }
    }

    ///@dev gas !!!
    function trainStation(address _trainAddress)
        public
        nonReentrant
        returns (bool success)
    {
        require(lastStation[_trainAddress].at != block.number, "Departing");
        require(isInStation(_trainAddress), "Train moving. (Chu, Chu)");

        Train memory train = getTrainByPool[_trainAddress];
        IERC20 token = IERC20(train.meta.buybackToken);

        if (allowConductorWithdrawal[_trainAddress][1] > 1) {
            withdrawBuybackToken(_trainAddress);
        }
        /// if vault
        IVault vault = trainAddressVault[_trainAddress];
        IUniswapV2Pair pair = IUniswapV2Pair(_trainAddress);
        uint256 vYield;
        uint256 pYield;
        /// @dev inCustoday weight. weird vibes.
        bool isVault = address(vault) != address(0);
        if (isVault) {
            vYield = (vault.maxAvailableShares() / train.yieldSharesTotal);
        } else {
            pYield =
                (pair.balanceOf(address(this)) - train.inCustody) /
                train.yieldSharesTotal;
        }
        for (uint256 i = 0; i < offBoardingQueue[_trainAddress].length; i++) {
            /// @dev fuzzy
            Ticket memory t = offBoardingQueue[_trainAddress][i];
            uint256 _shares = t.bagSize * (t.destination - t.departure);

            if (isVault)
                vault.withdraw(
                    (vYield * _shares + t.bagSize),
                    ticketByNftId[t.nftid][0]
                );
            else
                pair.transfer(
                    ticketByNftId[t.nftid][0],
                    (pYield * _shares + t.bagSize)
                );

            _burn(t.nftid);
        }

        offBoardingQueue[_trainAddress] = blanks;

        //////////////////////////

        // - buyback - yield

        // - onboard

        bool bagsToOnboard = token.balanceOf(address(this)) > 0;
        if (bagsToOnboard) {
            return true;
            /// deposit new token, non-buyback token in vault
        }

        //emit TrainInStation(_trainAddress, stationsBehind);
        ///@dev review OoO
        lastStation[_trainAddress].at = block.number;

        //stationsBehind++;
    }

    function requestOffBoarding(address _trainAddress)
        public
        nonReentrant
        returns (bool success)
    {
        Ticket memory ticket = userTrainTicket[msg.sender][_trainAddress];
        require(stationsLeft(ticket.nftid) <= 1, "maybe not next staton");

        offBoardingQueue[_trainAddress].push(ticket);
        Ticket memory emptyticket;
        //userTrainTicket[msg.sender][_trainAddress] = emptyticket;
        success = true;
    }

    /// @notice announces withdrawal intention on buybacktoken only
    /// @dev rugpulling timelock intention
    /// @param _trainAddress address of train
    /// @param _quantity uint256 amount of tokens to withdraw
    function conductorWithdrawal(
        uint64 _quantity,
        uint64 _wen,
        address _trainAddress
    ) public onlyTrainOnwer(_trainAddress) returns (bool success) {
        require(!isInStation(_trainAddress), "please wait");

        Train memory train = getTrainByPool[_trainAddress];
        /// @dev irrelevant if cyclelength is changeable
        require(_wen > 0, "never, cool");
        require(_quantity > 1, "swamp of nothingness");
        // require(lastStation[_trainAddress].ownedQty > _quantity, "never, cool");
        ///@notice case for 0 erc20 transfer .any?
        allowConductorWithdrawal[_trainAddress] = [
            train.config.cycleParams[0] * _wen + uint64(block.number),
            _quantity
        ];

        emit TrainConductorBeingWeird(_quantity, _trainAddress, msg.sender);
    }

    ////////### ERC721 Override

    ///////##########

    //////// Public Functions
    /////////////////////////////////

    /////////////////////////////////
    ////////  INTERNAL FUNCTIONS

    ///before ERC721 transfer
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        if (from != address(0)) {
            Ticket memory emptyticket;
            Ticket memory T = getTicketById(tokenId);
            uint256 toBurn = T.bagSize * (T.destination - T.departure);
            userTrainTicket[from][T.trainAddress] = emptyticket;
            decrementShares(T.trainAddress, toBurn);
            decrementBag(T.trainAddress, T.bagSize);
            decrementPassengers(T.trainAddress);
            ticketByNftId[T.nftid] = [address(0), address(0)];
        }
    }

    ////////  Internal Functions
    /////////////////////////////////

    /////////////////////////////////
    ////////  PRIVATE FUNCTIONS

    function tokenOut(
        address _token,
        uint256 _amount,
        address _train
    ) private returns (bool success) {
        IERC20 token = IERC20(_token);
        IVault vault = trainAddressVault[_train];
        uint256 prev = token.balanceOf(address(this));
        if (prev >= _amount) {
            success = token.transfer(msg.sender, _amount);
            require(
                token.balanceOf(address(this)) >= (prev - _amount),
                "token transfer failed"
            );
        } else if (address(vault) != address(0)) {
            ///@dev fuzzy
            uint256 sharesToConvert = (_amount / (vault.pricePerShare())) + 1;
            vault.withdraw(sharesToConvert);
            success = token.transfer(msg.sender, _amount);
        }
        if (!success) {
            success = IUniswapV2Pair(_train).transfer(msg.sender, _amount);
        }
    }

    function withdrawBuybackToken(address _trainAddress)
        private
        returns (bool success)
    {
        IERC20 token = IERC20(getTrainByPool[_trainAddress].meta.buybackToken);
        uint256 quantity = allowConductorWithdrawal[_trainAddress][1];
        if (
            isRugpullNow(_trainAddress) &&
            lastStation[_trainAddress].ownedQty > quantity
        ) {
            allowConductorWithdrawal[_trainAddress] = [0, 0];
            success = token.transfer(isTrainOwner[_trainAddress], quantity);
        }
        if (success) {
            lastStation[_trainAddress].ownedQty -= quantity;

            emit TrainConductorWithdrawal(
                address(token),
                _trainAddress,
                quantity
            );
        }
    }

    function incrementPassengers(address _trainId) private {
        getTrainByPool[_trainId].passengers++;
    }

    function decrementPassengers(address _trainId) private {
        getTrainByPool[_trainId].passengers--;
    }

    function incrementBag(address _trainId, uint256 _bagSize) private {
        getTrainByPool[_trainId].inCustody += _bagSize;
    }

    function decrementBag(address _trainId, uint256 _bagSize) private {
        getTrainByPool[_trainId].inCustody -= _bagSize;
    }

    function decrementShares(address _trainId, uint256 _shares) private {
        getTrainByPool[_trainId].yieldSharesTotal -= _shares;
    }

    function incrementShares(
        address _trainId,
        uint256 _proposedDistance,
        uint256 _bagSize
    ) private {
        getTrainByPool[_trainId].yieldSharesTotal +=
            _proposedDistance *
            _bagSize;
    }

    //////// Private Functions
    /////////////////////////////////

    /////////////////////////////////
    ////////  VIEW FUNCTIONS

    /// @param _bToken address of the base token
    /// @param _denominator address of the quote token
    function isValidPool(address _bToken, address _denominator)
        public
        view
        returns (address poolAddress)
    {
        poolAddress = uniswapV2.getPair(_bToken, _denominator);
    }

    function getTicket(address _user, address _train)
        public
        view
        returns (Ticket memory ticket)
    {
        ticket = userTrainTicket[_user][_train];
    }

    function getTicketsByPrice(address _train, uint64 _perPrice)
        public
        view
        returns (Ticket[] memory)
    {
        return ticketsFromPrice[_train][_perPrice];
    }

    function getTrain(address _trainAddress)
        public
        view
        returns (Train memory train)
    {
        train = getTrainByPool[_trainAddress];
    }

    /// @dev should lock train records during station operations
    function isInStation(address _trainAddress)
        public
        view
        returns (bool inStation)
    {
        if (
            getTrainByPool[_trainAddress].config.cycleParams[0] +
                lastStation[_trainAddress].at ==
            block.number
        ) inStation = true;
        /// @dev strinct equality. gas wars
    }

    function getTicketById(uint256 _id)
        public
        view
        returns (Ticket memory ticket)
    {
        address[2] memory _from = ticketByNftId[_id];
        ticket = getTicket(_from[0], _from[1]);
    }

    function isRugpullNow(address _trainAddress) public view returns (bool) {
        return allowConductorWithdrawal[_trainAddress][0] < block.number;
    }

    function stationsLeft(uint256 _nftID) public view returns (uint64) {
        address[2] memory whoTrain = ticketByNftId[_nftID]; ///addres /
        Ticket memory ticket = userTrainTicket[whoTrain[0]][whoTrain[1]];
        return
            uint64(
                (ticket.destination - block.number) /
                    (getTrainByPool[ticket.trainAddress].config.cycleParams[0])
            );
    }

    function tokenHasVault(address _buybackERC)
        public
        view
        returns (address vault)
    {
        try yRegistry.latestVault(_buybackERC) returns (address response) {
            if (response != address(0)) {
                vault = response;
            }
        } catch {
            vault = address(0);
        }
    }

    //////// View Functions
    //////////////////////////////////
}
