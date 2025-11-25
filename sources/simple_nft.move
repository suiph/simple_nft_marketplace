// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// NFT Marketplace with minting, listing, and purchase functionality
module nft::nft_marketplace {
    use std::string;
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::url::{Self, Url};

    // ===== Errors =====

    const EInvalidPrice: u64 = 0;
    const EInsufficientPayment: u64 = 1;
    const ENotSeller: u64 = 2;
    const EListingNotFound: u64 = 3;
    const EUnauthorized: u64 = 4; // Error for unauthorized access

    /// An NFT that can be minted, listed, and traded
    public struct NFT has key, store {
        id: UID,
        /// Name for the token
        name: string::String,
        /// Description of the token
        description: string::String,
        /// URL for the token image
        url: Url,
    }

    /// A listing object that holds an NFT for sale.
    /// It is a first-class object (has key) and is adopted by the Marketplace via DOF.
    public struct Listing has key, store {
        id: UID, // Required since it has 'key' ability
        /// The NFT object
        nft: NFT,
        /// Price in MIST (1 SUI = 1,000,000,000 MIST)
        price: u64,
        /// The seller's address
        seller: address,
    }

    /// Shared marketplace object to track all listings
    public struct Marketplace<phantom SUI> has key {
        id: UID,
        /// The address of the entity that created and published the module
        publisher: address,
        /// Balance to hold marketplace fees (optional)
        balance: Balance<SUI>,
        /// Listings index: Key is NFT ID, Value is the Listing object's ID.
        /// Listings are attached as Dynamic Object Fields to marketplace.id, keyed by the NFT's ID.
        listings: Bag, // Bag index added
        /// Payments received (for demonstration; not used in this version)
        payments: Table<address, Coin<SUI>>,
    }

    // ===== Events =====

    public struct MintNFTEvent has copy, drop {
        object_id: ID,
        creator: address,
        name: string::String,
    }

    public struct ListNFTEvent has copy, drop {
        nft_id: ID,
        seller: address,
        price: u64,
    }

    public struct DelistNFTEvent has copy, drop {
        nft_id: ID,
        seller: address,
    }

    public struct PurchaseNFTEvent has copy, drop {
        nft_id: ID,
        buyer: address,
        seller: address,
        price: u64,
    }

    // ===== Initialization =====

    /// Initialize the marketplace (call once during deployment)
    fun init(ctx: &mut TxContext) {
        let marketplace = Marketplace<SUI> {
            id: object::new(ctx),
            publisher: tx_context::sender(ctx), // Store the publisher address
            balance: balance::zero(),
            listings: bag::new(ctx), // Initialize the Bag
            payments: table::new<address, Coin<SUI>>(ctx),
        };
        // The Marketplace remains a shared object
        transfer::share_object(marketplace)
    }

    // ===== Entry Functions for External Interaction =====

    /// Mint a new NFT and transfer to sender (entry function for wallet/IDE interaction)
    entry fun mint(name: vector<u8>, description: vector<u8>, url: vector<u8>, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let nft = NFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            url: url::new_unsafe_from_bytes(url),
        };

        sui::event::emit(MintNFTEvent {
            object_id: object::uid_to_inner(&nft.id),
            creator: sender,
            name: nft.name,
        });

        transfer::public_transfer(nft, sender)
    }

    /// Update NFT description (entry function)
    entry fun update_nft_description(nft: &mut NFT, new_description: vector<u8>) {
        nft.description = string::utf8(new_description)
    }

    /// Burn an NFT (entry function)
    entry fun burn(nft: NFT) {
        let NFT { id, name: _, description: _, url: _ } = nft;
        object::delete(id)
    }

    /// List an NFT for sale (entry function)
    entry fun list<T: key + store, SUI>(
        marketplace: &mut Marketplace<SUI>,
        nft: NFT,
        price: u64,
        ctx: &mut TxContext,
    ) {
        assert!(price > 0, EInvalidPrice);

        let nft_id = nft_id(&nft);
        let seller = tx_context::sender(ctx);

        // Create the Listing object
        let mut listing = Listing {
            id: object::new(ctx),
            nft,
            price,
            seller,
        };

        // Add an index entry to the Bag: Key=NFT ID, Value=Listing
        bag::add(&mut marketplace.listings, nft_id, listing);

        sui::event::emit(ListNFTEvent {
            nft_id,
            seller,
            price,
        })
    }

    // Delist an NFT (entry function)
    entry fun delist_and_take<T: key + store, SUI>(
        marketplace: &mut Marketplace<SUI>,
        nft_id: ID,
        ctx: &TxContext,
    ) {
        // Remove listing and get the nft back. Only owner can do that.
        let Listing {
            id,
            nft,
            seller,
            price: _,
        } = bag::remove(&mut marketplace.listings, nft_id);

        assert!(tx_context::sender(ctx) == seller, ENotSeller);

        sui::event::emit(DelistNFTEvent {
            nft_id,
            seller,
        });

        // Return NFT to seller
        transfer::public_transfer(nft, seller);

        // Delete the Listing object as it is no longer needed.
        object::delete(id)
    }

    /// Purchase a listed NFT (entry function)
    entry fun buy_and_take<T: key + store, SUI>(
        marketplace: &mut Marketplace<SUI>,
        nft_id: ID,
        mut payment: Coin<SUI>, // Passed by value for transfer/destruction
        ctx: &mut TxContext,
    ) {
        // Remove and retrieve the Listing object from Bag
        let Listing {
            id,
            nft,
            price,
            seller,
        } = bag::remove(&mut marketplace.listings, nft_id);

        let payment_value = coin::value(&payment);

        assert!(payment_value >= price, EInsufficientPayment);

        let buyer = tx_context::sender(ctx);

        // Calculate marketplace fee (2% fee)
        let fee_amount = price * 2 / 100;
        let seller_amount = price - fee_amount;

        // Split payment
        let fee_coin = coin::split(&mut payment, fee_amount, ctx);
        let seller_coin = coin::split(&mut payment, seller_amount, ctx);

        // Check if there's already a Coin hanging and merge `payment` with it.
        // Otherwise attach `payment` to the `Marketplace` under seller's `address`.
        if (table::contains<address, Coin<SUI>>(&marketplace.payments, seller)) {
            coin::join(
                table::borrow_mut<address, Coin<SUI>>(&mut marketplace.payments, seller),
                seller_coin,
            )
        } else {
            table::add(&mut marketplace.payments, seller, seller_coin)
        };

        // Add fee to marketplace balance
        balance::join(&mut marketplace.balance, coin::into_balance(fee_coin));

        // Return excess payment to buyer
        if (coin::value(&payment) > 0) {
            transfer::public_transfer(payment, buyer);
        } else {
            coin::destroy_zero(payment);
        };

        sui::event::emit(PurchaseNFTEvent {
            nft_id,
            buyer,
            seller,
            price,
        });

        // Transfer NFT to buyer
        transfer::public_transfer(nft, buyer);

        // Delete the Listing object as the sale is complete.
        object::delete(id)
    }

    #[lint_allow(self_transfer)]
    /// Call [`take_profits`] and transfer Coin object to the sender.
    entry fun take_profits_and_keep<SUI>(marketplace: &mut Marketplace<SUI>, ctx: &mut TxContext) {
        // Take profits from the marketplace payments table
        let sells = table::remove<address, Coin<SUI>>(
            &mut marketplace.payments,
            tx_context::sender(ctx),
        );
        transfer::public_transfer(sells, tx_context::sender(ctx))
    }

    /// Withdraw marketplace fees (Restricted to the publisher)
    entry fun withdraw_marketplace_fees(
        marketplace: &mut Marketplace<SUI>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        // Check that the sender is the original publisher of the module
        assert!(tx_context::sender(ctx) == marketplace.publisher, EUnauthorized);

        let withdrawn = coin::take(&mut marketplace.balance, amount, ctx);
        transfer::public_transfer(withdrawn, recipient)
    }

    // ===== Getter Functions (View Functions) =====

    /// Get the NFT's name
    public fun name(nft: &NFT): &string::String {
        &nft.name
    }

    /// Get the NFT's descriptio
    public fun description(nft: &NFT): &string::String {
        &nft.description
    }

    /// Get the NFT's URL
    public fun url(nft: &NFT): &Url {
        &nft.url
    }

    /// Get the NFT's ID
    public fun nft_id(nft: &NFT): ID {
        object::id(nft)
    }

    /// Check if a listing exists
    public fun is_listed(marketplace: &Marketplace<SUI>, nft_id: ID): bool {
        // Check existence via Bag index
        bag::contains<ID>(&marketplace.listings, nft_id)
    }

    /// Get listing price
    public fun listing_price(marketplace: &Marketplace<SUI>, nft_id: ID): u64 {
        assert!(is_listed(marketplace, nft_id), EListingNotFound);

        let listing = bag::borrow<ID, Listing>(&marketplace.listings, nft_id);
        listing.price
    }

    /// Get listing seller
    public fun listing_seller(marketplace: &Marketplace<SUI>, nft_id: ID): address {
        assert!(is_listed(marketplace, nft_id), EListingNotFound);

        let listing = bag::borrow<ID, Listing>(&marketplace.listings, nft_id);
        listing.seller
    }

    /// Get the NFT ID for a listing (redundant, but kept for clarity on the pattern)
    public fun listing_nft_id(marketplace: &Marketplace<SUI>, nft_id: ID): ID {
        // Check if the listing exists using DOF check
        assert!(is_listed(marketplace, nft_id), EListingNotFound);

        nft_id
    }

    /// Get marketplace balance
    public fun marketplace_balance(marketplace: &Marketplace<SUI>): u64 {
        balance::value(&marketplace.balance)
    }

    /// Get the number of listings in the marketplace
    public fun listing_count(marketplace: &Marketplace<SUI>): u64 {
        bag::length(&marketplace.listings)
    }
}
