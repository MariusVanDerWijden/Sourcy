//---------------------------------------------------------------
// Storage Contract to store data 
// written by Marius van der Wijden 
// <https://github.com/MariusVanDerWijden>
//---------------------------------------------------------------

pragma solidity ^0.4.21;

contract StorageContract{

	/*
		Events thrown during contract lifetime
	*/
	event Storage_Opened();

	event Source_Added(
		string topic, 
		string abstractDesc, 
		address provider);

	event Source_Bidded(
		uint256 slot, 
		address provider, 
		address user, 
		bytes firstKeyHalfEnc, 
    	bytes32 firstHalfHash);

    event Bid_Accepted(
    	uint256 slot,
    	address provider,
    	address user, 
    	bytes32 secondKeyHalf);

    event Exchange_Finished(
    	uint256 slot,
    	address provider,
    	address user);

    event Exchange_Timeouted(
    	uint256 slot,
    	address provider,
    	address user);

    event Exchange_Dispute_Successful(
    	uint256 slot,
    	address provider,
    	address user);

    event Exchange_Dispute_Failed(
    	uint256 slot,
    	address provider,
    	address user);

    event User_Refunded(
    	uint256 slot,
    	address provider,
    	address user);

    event Provider_Refunded(
    	uint256 slot,
    	address provider);

    event Storage_Closed(uint256 slot);

    event Selfdestruct();

    //States for the internal state machines
	enum StorageState {CLOSED, OPEN, REFUND}
	enum FairExchangeState {CLOSED, PROPOSED, ACCEPTED}

	//Structure that contains the stored data
	struct Storage 
	{
		address provider; //address of the data provider
		uint256 providerValue; //value of eth staked from the provider
		string abstractDesc; //abstract description of the encrypted data
		string topic; //topic of the encrypted data
		bytes encryptedSource; //encrypted data
		bytes32 hashedKey; //hash of the key used to encrypt the data

		StorageState state; //current state of the storage
		uint256 timeout; //timeout until encrypted data is public
		//helper
		mapping(address => uint256) userValues; //eth provided by users
		uint256 userCount; //amount of users that are interested in this data
		uint256 userValueSum;
		
		uint256 refundOverhead; //temporary variable 
		//(holds the amount of money each user gets from the staked eth in case of cheating)
		mapping(address => FairExchange) exchanges; //FairExchanges for this storage cell
    }
    
    //Structure for the fair exchange of data
    struct FairExchange {
        address user;
		uint256 value; //Amount of eth he wants to pay
		bytes firstKeyHalfEnc; //the first half of the key, encrypted with the public key of the provider
		bytes32 firstHalfHash; //the hash of the first half
		bytes32 secondKeyHalf; //the second half of the key
		FairExchangeState state;
		uint256 timeout;
    }

    //internal variables used in the contract
	mapping(uint256 => Storage) private sources;
	uint constant maxTimeout = 100 minutes;
	uint constant maxExchangeTimeout = 30 minutes;
	uint256 exchangeCount; //open fair exchanges
	uint256 storageCount; //open storages
	address owner; //owner of the smart contract

	//Constructor function for the StorageContract
	constructor() public
	{
		emit Storage_Opened();
		owner = msg.sender;
	}

	function addNewSource(
		uint256 slot, 
		string _abstract, 
		string _topic,
		bytes _encryptedSource,
		bytes32 _hashedKey, 
		uint256 _timeout) public payable
	{
		require(sources[slot].state == StorageState.CLOSED);
		require(_timeout > maxExchangeTimeout * 2);
		sources[slot].provider = msg.sender;
		sources[slot].abstractDesc = _abstract;
		sources[slot].encryptedSource = _encryptedSource;
		sources[slot].topic = _topic;
		sources[slot].hashedKey = _hashedKey;
		sources[slot].providerValue = msg.value;
		sources[slot].timeout = _timeout;
		sources[slot].state = StorageState.OPEN;
		storageCount = storageCount + 1;
		emit Source_Added(_topic, _abstract, msg.sender);
	}

	//user bids on data and provides encrypted keys for the fair exchange
	function bidOnSource(
    	uint256 slot, 
    	bytes _firstKeyHalfEnc, 
    	bytes32 _firstHalfHash) public payable
	{
		require(sources[slot].state == StorageState.OPEN);
		require(sources[slot].timeout > now);
		require(msg.value > 0);
		require(now + maxTimeout < sources[slot].timeout);
		require(sources[slot].exchanges[msg.sender].state == FairExchangeState.CLOSED);
		sources[slot].exchanges[msg.sender].user = msg.sender;
		sources[slot].exchanges[msg.sender].state = FairExchangeState.PROPOSED;
		sources[slot].exchanges[msg.sender].firstKeyHalfEnc = _firstKeyHalfEnc;
		sources[slot].exchanges[msg.sender].firstHalfHash = _firstHalfHash;
		sources[slot].exchanges[msg.sender].value = msg.value;
		sources[slot].exchanges[msg.sender].timeout = now + maxTimeout;
		exchangeCount = exchangeCount + 1;
		emit Source_Bidded(
			slot, 
			sources[slot].provider, 
			msg.sender, 
			_firstKeyHalfEnc, 
    		_firstHalfHash);
	}

	//provider accepts the bid of the user
	function acceptBid (
		uint256 slot,
		address exchange, 
		bytes32 _secondKeyHalf) public
	{
		require(sources[slot].provider == msg.sender);
		require(now < sources[slot].exchanges[exchange].timeout);
		require(sources[slot].exchanges[exchange].state == FairExchangeState.PROPOSED);
		sources[slot].exchanges[exchange].secondKeyHalf = _secondKeyHalf;
		sources[slot].exchanges[exchange].state = FairExchangeState.ACCEPTED;
		sources[slot].exchanges[exchange].timeout = now + maxTimeout;
		emit Bid_Accepted(
    		slot,
    		sources[slot].provider,
    		exchange, 
    		_secondKeyHalf);
	}

	//successful exchange, money is now locked in escrow
	function finishExchange (uint256 slot, address exchange) public
	{
		require(sources[slot].exchanges[exchange].state == FairExchangeState.ACCEPTED);
		require(now > sources[slot].exchanges[exchange].timeout || exchange == msg.sender);
		sources[slot].exchanges[exchange].state = FairExchangeState.CLOSED;
		exchangeCount = exchangeCount - 1;
		sources[slot].userValues[exchange] += sources[slot].exchanges[exchange].value;
		sources[slot].userValueSum += sources[slot].exchanges[exchange].value;
		sources[slot].userCount += 1;
		emit Exchange_Finished(
    		slot,
    		sources[slot].provider,
    		exchange);
	}

	//provider did not accept the exchange
	function timeoutExchange (uint256 slot, address exchange) public
	{
		require(sources[slot].exchanges[exchange].state == FairExchangeState.PROPOSED);
		require(now > sources[slot].exchanges[exchange].timeout);
		sources[slot].exchanges[exchange].state = FairExchangeState.CLOSED;
		uint256 tmp = sources[slot].exchanges[exchange].value;
		sources[slot].exchanges[exchange].value = 0;
		require(sources[slot].exchanges[exchange].user.send(tmp));
		exchangeCount = exchangeCount - 1;
		emit Exchange_Timeouted(
    		slot,
    		sources[slot].provider,
    		exchange);
	}

	function disputeExchange(uint256 slot, bytes32 firstKeyHalf) public
	{
		require(sources[slot].exchanges[msg.sender].state == FairExchangeState.ACCEPTED);
		require(now < sources[slot].exchanges[msg.sender].timeout);
		require(keccak256(abi.encodePacked(firstKeyHalf)) 
		    == sources[slot].exchanges[msg.sender].firstHalfHash);
		bytes32 key = firstKeyHalf ^ sources[slot].exchanges[msg.sender].secondKeyHalf;
		bool cheated = (keccak256(abi.encodePacked(key)) != sources[slot].hashedKey);
		if(cheated)
		{
			sources[slot].state = StorageState.REFUND;
			sources[slot].refundOverhead = 
				sources[slot].userValueSum / sources[slot].providerValue;
			emit Exchange_Dispute_Successful(
    			slot,
    			sources[slot].provider,
    			msg.sender);
		}
		else
		{
			uint256 tmp = sources[slot].exchanges[msg.sender].value;
			sources[slot].exchanges[msg.sender].value = 0;
			sources[slot].provider.transfer(tmp);
			emit Exchange_Dispute_Failed(
    			slot,
    			sources[slot].provider,
    			msg.sender);
		}
	}

	function refundUser(uint256 slot) public
	{
		require(sources[slot].state == StorageState.REFUND);
		require(sources[slot].userValues[msg.sender] > 0);
		uint tmp = sources[slot].userValues[msg.sender] 
			+ sources[slot].refundOverhead;
		sources[slot].userValues[msg.sender] = 0;
		msg.sender.transfer(tmp);
		sources[slot].userCount -= 1;
		emit User_Refunded(slot, sources[slot].provider, msg.sender);
	}

	function refundProvider(uint256 slot) public 
	{
		require(now > sources[slot].timeout);
		require(sources[slot].state  == StorageState.OPEN);
		sources[slot].state = StorageState.CLOSED;
		uint256 tmp = sources[slot].userValueSum;
		sources[slot].userValueSum = 0;
		sources[slot].provider.transfer(tmp);
		sources[slot].userCount = 0;
		storageCount = storageCount - 1;
		emit Provider_Refunded(slot, sources[slot].provider);
	}
	
	function closeStorage(uint256 slot) public
	{
	    require(now > sources[slot].timeout);
	    require(sources[slot].userCount == 0);
	    sources[slot].state = StorageState.CLOSED;
	    storageCount = storageCount - 1;
	    emit Storage_Closed(slot);
	}
	
	function close() public
	{
	    require(msg.sender == owner);
	    require(storageCount == 0);
	    emit Selfdestruct();
	    selfdestruct(owner);
	}
}