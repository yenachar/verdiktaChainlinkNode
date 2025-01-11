// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
using Chainlink for Chainlink.Request;

/**
 * @title AIChainlinkRequest
 * @dev Aggregates AI evaluations from multiple Chainlink operators
 */
contract AIChainlinkRequest is ChainlinkClient, Ownable {
    using Chainlink for Chainlink.Request;

    struct OracleConfig {
        address operator;
        bytes32 jobId;
        uint256 fee;
        bool isActive;
    }

    struct Response {
        uint256[] likelihoods;
        string justificationCID;
        bytes32 requestId;
        bool included;  // Whether this response is included in final aggregation
    }

    struct AggregatedEvaluation {
        Response[] responses;
        uint256[] aggregatedLikelihoods;
        uint256 responseCount;
        uint256 expectedResponses;
        bool isComplete;
        mapping(bytes32 => bool) requestIds;  // Track individual oracle request IDs
    }

    // Mapping from aggregator request ID to aggregated results
    mapping(bytes32 => AggregatedEvaluation) public aggregatedEvaluations;
    
    // Mapping from operator request ID to aggregator request ID
    mapping(bytes32 => bytes32) public requestIdToAggregatorId;
    
    // Array of oracle configurations
    OracleConfig[] public oracles;
    
    // Number of oracle responses required per request
    uint256 public requiredOracleQueries;
    
    // Minimum number of unique oracle responses needed for valid aggregation
    uint256 public minimumResponses;
    
    // Events
    event RequiredQueriesUpdated(uint256 newRequiredQueries);
    event NewAggregationRequest(bytes32 indexed aggregatorRequestId, string[] cids);
    event OracleRequestSent(bytes32 indexed aggregatorRequestId, bytes32 indexed oracleRequestId, address operator);
    event OracleResponseReceived(bytes32 indexed aggregatorRequestId, bytes32 indexed oracleRequestId);
    event AggregationCompleted(bytes32 indexed aggregatorRequestId, uint256[] aggregatedLikelihoods);

    /**
     * @notice Constructor sets initial parameters
     * @param _link The LINK token address
     * @param _minimumResponses Minimum number of oracle responses required
     */
    constructor(
        address _link,
        uint256 _minimumResponses,
        uint256 _requiredOracleQueries
    ) Ownable(msg.sender) {
        require(_minimumResponses > 0, "Minimum responses must be greater than 0");
        require(_requiredOracleQueries >= _minimumResponses, "Required queries must be >= minimum responses");
        _setChainlinkToken(_link);
        minimumResponses = _minimumResponses;
        requiredOracleQueries = _requiredOracleQueries;
    }

    /**
     * @notice Add a new oracle configuration
     * @param operator Address of the Chainlink operator contract
     * @param jobId Job ID for this oracle
     * @param fee LINK fee for this oracle
     */
   function addOracle(address operator, uint256 jobId, uint256 fee) external onlyOwner {
       require(operator != address(0), "Invalid operator address");
       require(fee > 0, "Fee must be greater than 0");
    
       bytes32 bytesJobId = bytes32(jobId);
    
       oracles.push(OracleConfig({
           operator: operator,
           jobId: bytesJobId,
           fee: fee,
           isActive: true
       }));
       // Approve the operator to spend LINK
       LinkTokenInterface link = LinkTokenInterface(_chainlinkTokenAddress());
       require(link.approve(operator, type(uint256).max), "Failed to approve LINK");
   }

    /**
     * @notice Deactivate an oracle
     * @param index Index of the oracle in the oracles array
     */
    function deactivateOracle(uint256 index) external onlyOwner {
        require(index < oracles.length, "Invalid oracle index");
        oracles[index].isActive = false;
    }

    /**
     * @notice Set the required number of oracle queries per request
     * @param _requiredQueries New number of required queries
     */
    function setRequiredOracleQueries(uint256 _requiredQueries) external onlyOwner {
        require(_requiredQueries >= minimumResponses, "Required queries must be >= minimum responses");
        requiredOracleQueries = _requiredQueries;
        emit RequiredQueriesUpdated(_requiredQueries);
    }

    /**
     * @notice Request evaluations from random oracles, with possible repeats if needed
     * @param cids Array of IPFS CIDs to be evaluated
     * @return aggregatorRequestId Unique ID for this aggregation request
     */
    function requestAIEvaluation(string[] memory cids) external returns (bytes32) {
        require(cids.length > 0, "CIDs array must not be empty");
        
        // Generate unique aggregator request ID and concatenate CIDs
        string memory cidsConcatenated = concatenateCids(cids);
        bytes32 aggregatorRequestId = keccak256(abi.encodePacked(block.timestamp, msg.sender, cidsConcatenated));
        
        // Count active oracles and store their indices
        uint256[] memory activeIndices = new uint256[](oracles.length);
        uint256 activeOracleCount = 0;
        
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i].isActive) {
                activeIndices[activeOracleCount] = i;
                activeOracleCount++;
            }
        }
        
        require(activeOracleCount > 0, "No active oracles");
        
        // Initialize the aggregated evaluation
        aggregatedEvaluations[aggregatorRequestId].expectedResponses = requiredOracleQueries;
        aggregatedEvaluations[aggregatorRequestId].isComplete = false;
        
        // Calculate how many rounds of selection we need
        uint256[] memory selectedIndices = new uint256[](requiredOracleQueries);
        
        for (uint256 i = 0; i < requiredOracleQueries; i++) {
            // Select a random oracle index, allowing repeats
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                msg.sender,
                i
            ))) % activeOracleCount;
            
            uint256 oracleIndex = activeIndices[randomIndex];
            selectedIndices[i] = oracleIndex;
            
            bytes32 oracleRequestId = sendOracleRequest(
                oracles[oracleIndex].operator,
                oracles[oracleIndex].jobId,
                oracles[oracleIndex].fee,
                cidsConcatenated,
                aggregatorRequestId
            );
            
            // Map the oracle request ID to our aggregator request ID
            requestIdToAggregatorId[oracleRequestId] = aggregatorRequestId;
            aggregatedEvaluations[aggregatorRequestId].requestIds[oracleRequestId] = true;
            
            emit OracleRequestSent(aggregatorRequestId, oracleRequestId, oracles[oracleIndex].operator);
        }
        
        emit NewAggregationRequest(aggregatorRequestId, cids);
        return aggregatorRequestId;
    }

    /**
     * @notice Send a request to a single oracle
     */
    function sendOracleRequest(
        address operator,
        bytes32 jobId,
        uint256 fee,
        string memory cidsConcatenated,
        bytes32 aggregatorRequestId
    ) internal returns (bytes32) {
        Chainlink.Request memory request = _buildOperatorRequest(jobId, this.fulfill.selector);
        request._add("cid", cidsConcatenated);

        // StringUtils.StringStore memory store;
        // store.store = bytes(cidsConcatenated);
        // request.buf = StringUtils.encode(store);
        return _sendOperatorRequestTo(operator, request, fee);
    }

    /**
     * @notice Callback function for oracles to submit their evaluations
     */
    function fulfill(
        bytes32 _requestId,
        uint256[] memory likelihoods,
        string memory justificationCID
    ) public recordChainlinkFulfillment(_requestId) {
        require(likelihoods.length > 0, "Likelihoods array must not be empty");
        
        bytes32 aggregatorRequestId = requestIdToAggregatorId[_requestId];
        require(aggregatorRequestId != bytes32(0), "Unknown request ID");
        
        AggregatedEvaluation storage aggEval = aggregatedEvaluations[aggregatorRequestId];
        require(!aggEval.isComplete, "Aggregation already completed");
        require(aggEval.requestIds[_requestId], "Invalid request ID");

        // Store the new response
        Response memory newResponse = Response({
            likelihoods: likelihoods,
            justificationCID: justificationCID,
            requestId: _requestId,
            included: true  // Default to included, will be updated in finalization
        });
        
        aggEval.responses.push(newResponse);
        aggEval.responseCount++;
        
        emit OracleResponseReceived(aggregatorRequestId, _requestId);
        
        // Check if we have enough responses to complete aggregation
        if (aggEval.responseCount >= requiredOracleQueries) {
            finalizeAggregation(aggregatorRequestId);
        }
    }

    /**
     * @notice Calculate the Euclidean distance between two likelihood arrays
     */
    function calculateDistance(uint256[] memory a, uint256[] memory b) internal pure returns (uint256) {
        require(a.length == b.length, "Arrays must be same length");
        uint256 sumSquares = 0;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] > b[i]) {
                sumSquares += (a[i] - b[i]) * (a[i] - b[i]);
            } else {
                sumSquares += (b[i] - a[i]) * (b[i] - a[i]);
            }
        }
        return sumSquares;  // Note: We don't take the square root to avoid floating point
    }

    /**
     * @notice Find the response that's furthest from the others (the outlier)
     */
    function findOutlier(Response[] memory responses) internal pure returns (uint256) {
        require(responses.length > 1, "Need at least 2 responses to find outlier");
        
        uint256 maxTotalDistance = 0;
        uint256 outlierIndex = 0;
        
        // For each response, calculate total distance to all other responses
        for (uint256 i = 0; i < responses.length; i++) {
            uint256 totalDistance = 0;
            for (uint256 j = 0; j < responses.length; j++) {
                if (i != j) {
                    totalDistance += calculateDistance(
                        responses[i].likelihoods,
                        responses[j].likelihoods
                    );
                }
            }
            if (totalDistance > maxTotalDistance) {
                maxTotalDistance = totalDistance;
                outlierIndex = i;
            }
        }
        
        return outlierIndex;
    }

    /**
     * @notice Finalize the aggregation by excluding the outlier and averaging the rest
     */
    function finalizeAggregation(bytes32 aggregatorRequestId) internal {
        AggregatedEvaluation storage aggEval = aggregatedEvaluations[aggregatorRequestId];
        
        // Find and exclude the outlier
        uint256 outlierIndex = findOutlier(aggEval.responses);
        aggEval.responses[outlierIndex].included = false;
        
        // Count included responses and initialize aggregatedLikelihoods
        uint256 includedCount = 0;
        aggEval.aggregatedLikelihoods = new uint256[](aggEval.responses[0].likelihoods.length);
        
        // Sum up all non-outlier responses
        for (uint256 i = 0; i < aggEval.responses.length; i++) {
            if (aggEval.responses[i].included) {
                includedCount++;
                for (uint256 j = 0; j < aggEval.responses[i].likelihoods.length; j++) {
                    aggEval.aggregatedLikelihoods[j] += aggEval.responses[i].likelihoods[j];
                }
            }
        }
        
        // Calculate averages
        for (uint256 i = 0; i < aggEval.aggregatedLikelihoods.length; i++) {
            aggEval.aggregatedLikelihoods[i] = aggEval.aggregatedLikelihoods[i] / includedCount;
        }
        
        aggEval.isComplete = true;
        emit AggregationCompleted(aggregatorRequestId, aggEval.aggregatedLikelihoods);
    }

    /**
     * @notice Select random indices from an array
     * @param indices Array of available indices
     * @param totalCount Number of available indices
     * @param selectCount Number of indices to select
     * @return selectedIndices Array of randomly selected indices
     */
    function selectRandomIndices(
        uint256[] memory indices,
        uint256 totalCount,
        uint256 selectCount
    ) internal view returns (uint256[] memory) {
        require(totalCount >= selectCount, "Not enough indices to select from");
        
        uint256[] memory selectedIndices = new uint256[](selectCount);
        uint256[] memory remainingIndices = new uint256[](totalCount);
        
        // Copy indices to working array
        for (uint256 i = 0; i < totalCount; i++) {
            remainingIndices[i] = indices[i];
        }
        
        // Select random indices using block-based randomness
        for (uint256 i = 0; i < selectCount; i++) {
            uint256 remainingCount = totalCount - i;
            uint256 randomIndex = uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                msg.sender,
                i
            ))) % remainingCount;
            
            // Store selected index
            selectedIndices[i] = remainingIndices[randomIndex];
            
            // Move last element to selected position to avoid reusing indices
            remainingIndices[randomIndex] = remainingIndices[remainingCount - 1];
        }
        
        return selectedIndices;
    }

    /**
     * @notice Helper function to concatenate CIDs
     */
    function concatenateCids(string[] memory cids) internal pure returns (string memory) {
        bytes memory concatenatedCids;
        for (uint256 i = 0; i < cids.length; i++) {
            concatenatedCids = abi.encodePacked(concatenatedCids, cids[i]);
            if (i < cids.length - 1) {
                concatenatedCids = abi.encodePacked(concatenatedCids, ",");
            }
        }
        return string(concatenatedCids);
    }

    /**
     * @notice Get the current aggregation status and results
     */
    function getEvaluation(bytes32 aggregatorRequestId) external view returns (
        uint256[] memory likelihoods,
        string[] memory justificationCIDs,
        // uint256 responseCount,
        // uint256 expectedResponses,
        bool exists
    ) {
        AggregatedEvaluation storage aggEval = aggregatedEvaluations[aggregatorRequestId];
        
        // Count included justifications and collect them
        uint256 includedCount = 0;
        string[] memory includedJustifications = new string[](aggEval.responses.length);
        for (uint256 i = 0; i < aggEval.responses.length; i++) {
            if (aggEval.responses[i].included) {
                includedJustifications[includedCount] = aggEval.responses[i].justificationCID;
                includedCount++;
            }
        }
        
        // Create final justifications array of correct size
        string[] memory finalJustifications = new string[](includedCount);
        for (uint256 i = 0; i < includedCount; i++) {
            finalJustifications[i] = includedJustifications[i];
        }
        
        return (
            aggEval.aggregatedLikelihoods,
            finalJustifications,
            // aggEval.responseCount,
            // aggEval.expectedResponses,
            aggEval.responseCount > 0
        );
    }

    /**
     * @notice Get config info for first oracle
     */
    function getContractConfig() public view returns (
        address oracleAddr,
        address linkAddr,
        bytes32 jobid,
        uint256 fee
    ) {
        uint256 oracleIndex = 0; //first oracle
        return (oracles[oracleIndex].operator, _chainlinkTokenAddress(), oracles[oracleIndex].jobId, oracles[oracleIndex].fee);
    }

    /**
     * @notice Withdraw LINK tokens from the contract
     */
    function withdrawLink(address payable _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Invalid recipient address");
        LinkTokenInterface link = LinkTokenInterface(_chainlinkTokenAddress());
        require(link.transfer(_to, _amount), "Unable to transfer");
    }
}
