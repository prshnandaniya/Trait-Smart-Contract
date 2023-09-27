// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Trait is Ownable {
    event OfferCreated(StructOffer);

    event Status(StructOffer, OfferStatus);

    event ExecludedFromFees(address contractAddress);
    event IncludedFromFees(address contractAddress);
    event FeesClaimedByAdmin(uint256 feesValue);

    enum OfferStatus {
        pending,
        withdrawan,
        accepted,
        rejected
    }

    struct StructERC20Value {
        address erc20Contract;
        uint256 erc20Value;
    }

    struct StructERC721Value {
        address erc721Contract;
        uint256 erc721Id;
    }

    struct StructOffer {
        uint256 offerId;
        address sender;
        address receiver;
        uint256 offeredETH;
        uint256 requestedETH;
        StructERC20Value offeredERC20;
        StructERC20Value requestedERC20;
        StructERC721Value[] offeredERC721;
        StructERC721Value[] requestedERC721;
        uint256 timeStamp;
        uint256 validDuration;
        OfferStatus status;
    }

    struct StructAccount {
        uint256[] offersReceived;
        uint256[] offersCreated;
    }

    uint256 private _offerIds;
    address[] private _excludedFeesContracts;
    uint256 private _fees;
    uint256 private _feesCollected;
    uint256 private _feesClaimed;

    mapping(uint256 => StructOffer) private _mappingOffer;
    mapping(address => StructAccount) private _mappingAccounts;
    mapping(address => bool) public isExemptedFromFees;

    constructor(uint256 _feesInWei) {
        _fees = _feesInWei;
    }

    modifier tokensTransferable(address _token, uint256 _tokenId) {
        require(
            ERC721(_token).getApproved(_tokenId) == address(this),
            "The HTLC must have been designated an approved spender for the tokenId"
        );
        _;
    }

    modifier isValidOffer(uint256 _offerId) {
        StructOffer memory offerAccount = _mappingOffer[_offerId];
        require(
            offerAccount.sender != address(0),
            "Address zero cannot make offer."
        );
        require(
            offerAccount.receiver != address(0),
            "Cannot make offer to address zero."
        );
        require(
            offerAccount.status == OfferStatus.pending,
            "Offer already used."
        );
        _;
    }

    function createOffer(
        address _receiver,
        uint256 _offeredETH,
        uint256 _requestedETH,
        StructERC20Value memory _offeredERC20,
        StructERC20Value memory _requestedERC20,
        StructERC721Value[] memory _offeredERC721,
        StructERC721Value[] memory _requestedERC721,
        uint256 _offerValidDuration
    ) external payable returns (uint256 offerId) {
        uint256 msgValue = msg.value;
        address msgSender = msg.sender;
        uint256 currentTime = block.timestamp;

        offerId = _offerIds;

        ///@dev please ensure that there is sufficient allowance to successfully invoke the transferFrom function.
        for (uint8 i; i < _offeredERC721.length; i++) {
            ERC721(_offeredERC721[i].erc721Contract).transferFrom(
                msgSender,
                address(this),
                _offeredERC721[i].erc721Id
            );
        }

        ///@dev please ensure that there is sufficient allowance to successfully invoke the transferFrom function.
        if (
            _offeredERC20.erc20Contract != address(0) &&
            _offeredERC20.erc20Value > 0
        ) {
            IERC20(_offeredERC20.erc20Contract).transferFrom(
                msgSender,
                address(this),
                _offeredERC20.erc20Value
            );
        }

        if (!_isBalanceExcludedFromFees(msgSender)) {
            require(msgValue >= _fees + _offeredETH);
            _feesCollected += _fees;
        }

        StructOffer storage offerAccount = _mappingOffer[offerId];

        offerAccount.offerId = offerId;
        offerAccount.sender = msgSender;
        offerAccount.receiver = _receiver;
        offerAccount.offeredETH = _offeredETH;
        offerAccount.requestedETH = _requestedETH;
        offerAccount.offeredERC20 = _offeredERC20;
        offerAccount.requestedERC20 = _requestedERC20;

        for (uint256 i; i < _offeredERC721.length; ++i) {
            offerAccount.offeredERC721.push(_offeredERC721[i]);
        }

        for (uint256 i; i < _requestedERC721.length; ++i) {
            offerAccount.requestedERC721.push(_requestedERC721[i]);
        }

        offerAccount.timeStamp = currentTime;
        offerAccount.validDuration = _offerValidDuration;
        offerAccount.status = OfferStatus.pending;

        _mappingAccounts[msgSender].offersCreated.push(offerId);
        _mappingAccounts[_receiver].offersReceived.push(offerId);

        emit OfferCreated(_mappingOffer[offerId]);

        _offerIds++;
    }

    function acceptOffer(uint256 _offerId)
        external
        payable
        isValidOffer(_offerId)
    {
        address msgSender = msg.sender;
        uint256 msgValue = msg.value;

        StructOffer storage offerAccount = _mappingOffer[_offerId];
        require(msgSender == offerAccount.receiver, "You are not receiver.");
        require(
            msgValue >= offerAccount.requestedETH,
            "Receiver has not sent enough eth, offer creator requested."
        );
        require(
            block.timestamp <
                offerAccount.timeStamp + offerAccount.validDuration,
            "Offer expired."
        );

        ///@dev please ensure that there is sufficient allowance to successfully invoke the transferFrom function.
        for (uint8 i; i < offerAccount.offeredERC721.length; i++) {
            ERC721(offerAccount.offeredERC721[i].erc721Contract).transferFrom(
                address(this),
                offerAccount.receiver,
                offerAccount.offeredERC721[i].erc721Id
            );
        }

        ///@dev please ensure that there is sufficient allowance to successfully invoke the transferFrom function.
        for (uint8 i; i < offerAccount.requestedERC721.length; i++) {
            ERC721(offerAccount.requestedERC721[i].erc721Contract).transferFrom(
                    offerAccount.receiver,
                    offerAccount.sender,
                    offerAccount.requestedERC721[i].erc721Id
                );
        }

        if (offerAccount.offeredETH > 0) {
            payable(offerAccount.receiver).transfer(offerAccount.offeredETH);
        }

        if (offerAccount.requestedETH > 0) {
            payable(offerAccount.sender).transfer(offerAccount.requestedETH);
        }

        if (
            offerAccount.requestedERC20.erc20Contract != address(0) &&
            offerAccount.requestedERC20.erc20Value > 0
        ) {
            IERC20(offerAccount.requestedERC20.erc20Contract).transferFrom(
                msgSender,
                offerAccount.sender,
                offerAccount.requestedERC20.erc20Value
            );
        }

        ///@dev please ensure that there is sufficient allowance to successfully invoke the transferFrom function.
        if (
            offerAccount.offeredERC20.erc20Contract != address(0) &&
            offerAccount.offeredERC20.erc20Value > 0
        ) {
            IERC20(offerAccount.offeredERC20.erc20Contract).transfer(
                offerAccount.receiver,
                offerAccount.offeredERC20.erc20Value
            );
        }

        offerAccount.status = OfferStatus.accepted;
        emit Status(offerAccount, OfferStatus.accepted);
    }

    function rejectOffer(uint256 _offerId) external isValidOffer(_offerId) {
        address msgSender = msg.sender;
        StructOffer storage offerAccount = _mappingOffer[_offerId];

        require(
            msgSender == offerAccount.receiver,
            "Offer is not made to you."
        );

        for (uint8 i; i < offerAccount.offeredERC721.length; i++) {
            ERC721(offerAccount.offeredERC721[i].erc721Contract).transferFrom(
                address(this),
                offerAccount.sender,
                offerAccount.offeredERC721[i].erc721Id
            );
        }

        if (offerAccount.offeredETH > 0) {
            payable(offerAccount.sender).transfer(offerAccount.offeredETH);
        }

        if (
            offerAccount.offeredERC20.erc20Contract != address(0) &&
            offerAccount.offeredERC20.erc20Value > 0
        ) {
            IERC20(offerAccount.offeredERC20.erc20Contract).transfer(
                offerAccount.sender,
                offerAccount.offeredERC20.erc20Value
            );
        }

        offerAccount.status = OfferStatus.rejected;
        emit Status(offerAccount, OfferStatus.rejected);
    }

    function withdrawOffer(uint256 _offerId) external isValidOffer(_offerId) {
        address msgSender = msg.sender;

        StructOffer storage offerAccount = _mappingOffer[_offerId];

        require(
            msgSender == offerAccount.sender,
            "Only offer creator can withdrawOffer."
        );

        for (uint8 i; i < offerAccount.offeredERC721.length; i++) {
            ERC721(offerAccount.offeredERC721[i].erc721Contract).transferFrom(
                address(this),
                offerAccount.sender,
                offerAccount.offeredERC721[i].erc721Id
            );
        }

        if (offerAccount.offeredETH > 0) {
            payable(offerAccount.sender).transfer(offerAccount.offeredETH);
        }

        if (
            offerAccount.offeredERC20.erc20Contract != address(0) &&
            offerAccount.offeredERC20.erc20Value > 0
        ) {
            IERC20(offerAccount.offeredERC20.erc20Contract).transfer(
                offerAccount.sender,
                offerAccount.offeredERC20.erc20Value
            );
        }

        offerAccount.status = OfferStatus.withdrawan;

        emit Status(offerAccount, OfferStatus.withdrawan);
    }

    function getOfferById(uint256 _offerId)
        public
        view
        returns (StructOffer memory)
    {
        return _mappingOffer[_offerId];
    }

    function userOffers(address _userAddress)
        external
        view
        returns (
            uint256[] memory offersCreated,
            uint256[] memory offersReceived
        )
    {
        StructAccount memory userAccount = _mappingAccounts[_userAddress];
        offersCreated = userAccount.offersCreated;
        offersReceived = userAccount.offersReceived;
    }

    function allOffersCount() external view returns (uint256 offersCount) {
        if (_offerIds > 0) {
            offersCount = _offerIds + 1;
        }
    }

    function _isBalanceExcludedFromFees(address _userAddress)
        private
        view
        returns (bool _isExcluded)
    {
        address[] memory excludedContractsList = _excludedFeesContracts;
        if (excludedContractsList.length > 0) {
            for (uint8 i; i < excludedContractsList.length; ++i) {
                if (
                    ERC721(excludedContractsList[i]).balanceOf(_userAddress) > 0
                ) {
                    _isExcluded = true;
                    break;
                }
            }
        }
    }

    function getFeesExcludedList() external view returns (address[] memory) {
        return _excludedFeesContracts;
    }

    function includeInFees(address _contractAddress) external onlyOwner {
        require(
            isExemptedFromFees[_contractAddress],
            "Already included in exchange fees."
        );

        isExemptedFromFees[_contractAddress] = false;

        address[] memory excludedContractsList = _excludedFeesContracts;
        if (excludedContractsList.length > 0) {
            for (uint8 i; i < excludedContractsList.length; ++i) {
                if (excludedContractsList[i] == _contractAddress) {
                    _excludedFeesContracts[i] ==
                        _excludedFeesContracts[
                            _excludedFeesContracts.length - 1
                        ];
                    _excludedFeesContracts.pop();
                    break;
                }
            }
        }
    }

    function excludeFromExchangeFees(address _contractAddress)
        external
        onlyOwner
    {
        require(
            !isExemptedFromFees[_contractAddress],
            "Already excluded from exchange fees."
        );

        isExemptedFromFees[_contractAddress] = true;
        _excludedFeesContracts.push(_contractAddress);
    }

    function getFees() external view returns (uint256) {
        return _fees;
    }

    function setFees(uint256 _feesInWei) external onlyOwner {
        _fees = _feesInWei;
    }

    function getFeesCollected()
        external
        view
        returns (
            uint256 feesCollected,
            uint256 feesClaimed,
            uint256 feesPendingToClaim
        )
    {
        feesCollected = _feesCollected;
        feesClaimed = _feesClaimed;
        feesPendingToClaim = _feesCollected - _feesClaimed;
    }

    function claimFees() external onlyOwner {
        uint256 pendingFees = _feesCollected - _feesClaimed;
        require(pendingFees > 0, "No fees to claimed");
        _feesClaimed += pendingFees;

        payable(owner()).transfer(pendingFees);

        emit FeesClaimedByAdmin(pendingFees);
    }
}
