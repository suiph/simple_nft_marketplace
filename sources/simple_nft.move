// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// NFT Marketplace with minting, listing, and purchase functionality
module nft::nft_marketplace {
    use std::string;
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field as ofield;
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
    entry fun mint(
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        ctx: &mut TxContext,
    ) {
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
            price,
            seller,
        };

        // Add the Listing object as a Dynamic Object Field (Adoption)
        ofield::add(&mut listing.id, true, nft);

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
            mut id,
            seller,
            price: _,
        } = bag::remove(&mut marketplace.listings, nft_id);

        assert!(tx_context::sender(ctx) == seller, ENotSeller);

        // Remove and retrieve the Listing object from DOF
        let item: NFT = ofield::remove(&mut id, true);

        sui::event::emit(DelistNFTEvent {
            nft_id,
            seller,
        });

        // Return NFT to seller
        transfer::public_transfer(item, seller);

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
            mut id,
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

        let item: NFT = ofield::remove(&mut id, true);

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
        transfer::public_transfer(item, buyer);

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

    // ===== Public Functions for Composability =====

    /// Mint a new NFT and return it (composable pattern)
    public fun mint_composable(
        // Renamed to avoid collision with the entry fun's helper function 'mint'
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        ctx: &mut TxContext,
    ): NFT {
        // Return the correct NFT struct
        NFT {
            id: object::new(ctx),
            name: string::utf8(name),
            description: string::utf8(description),
            url: url::new_unsafe_from_bytes(url),
        }
    }

    /// Update the description of an NFT
    public fun update_description_composable(nft: &mut NFT, new_description: vector<u8>) {
        nft.description = string::utf8(new_description)
    }

    /// Burn an NFT permanently
    public fun burn_composable(nft: NFT) {
        let NFT { id, name: _, description: _, url: _ } = nft;
        object::delete(id)
    }

    /// List an NFT for sale at a specified price (Composable version using Marketplace)
    public fun list_nft_composable<SUI>(
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
            price,
            seller,
        };

        // Add the NFT object as a Dynamic Object Field (Adoption)
        ofield::add(&mut listing.id, true, nft); // NFT is stored as a DOF on the Listing object

        // Add an index entry to the Bag: Key=NFT ID, Value=Listing
        bag::add(&mut marketplace.listings, nft_id, listing);

        sui::event::emit(ListNFTEvent {
            nft_id,
            seller,
            price,
        })
    }

    /// Delist an NFT and return it (Composable version using Marketplace)
    public fun delist_nft_composable<SUI>(
        marketplace: &mut Marketplace<SUI>,
        nft_id: ID,
        ctx: &TxContext,
    ): NFT {
        // Remove listing and get the nft back. Only seller can do that.
        let Listing {
            mut id,
            seller,
            price: _,
        } = bag::remove(&mut marketplace.listings, nft_id);

        assert!(tx_context::sender(ctx) == seller, ENotSeller);

        // Remove and retrieve the NFT object from DOF
        let item: NFT = ofield::remove(&mut id, true);

        sui::event::emit(DelistNFTEvent {
            nft_id,
            seller,
        });

        // Delete the Listing object as it is no longer needed.
        object::delete(id);

        item // Return NFT to caller for next command
    }

    /// Purchase a listed NFT (Composable version using Marketplace)
    /// Returns the purchased NFT and the excess payment (if any)
    public fun purchase_nft_composable<SUI>(
        marketplace: &mut Marketplace<SUI>,
        nft_id: ID,
        mut payment: Coin<SUI>, // Passed by value
        ctx: &mut TxContext,
    ): (NFT, Option<Coin<SUI>>) {
        // Remove and retrieve the Listing object from Bag
        let Listing {
            mut id,
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

        // Deposit seller amount (Same logic as buy_and_take)
        if (table::contains<address, Coin<SUI>>(&marketplace.payments, seller)) {
            coin::join(
                table::borrow_mut<address, Coin<SUI>>(&mut marketplace.payments, seller),
                seller_coin,
            )
        } else {
            table::add(&mut marketplace.payments, seller, seller_coin)
        };

        // Retrieve the NFT from the Listing's DOF
        let item: NFT = ofield::remove(&mut id, true);

        // Add fee to marketplace balance
        balance::join(&mut marketplace.balance, coin::into_balance(fee_coin));

        sui::event::emit(PurchaseNFTEvent {
            nft_id,
            buyer,
            seller,
            price,
        });

        // Delete the Listing object as the sale is complete.
        object::delete(id);

        let excess_payment = if (coin::value(&payment) > 0) {
            option::some(payment)
        } else {
            coin::destroy_zero(payment);
            option::none()
        };

        (item, excess_payment) // Return NFT and excess payment (if any)
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
        // Check existence via DOF
        ofield::exists_with_type<ID, Listing>(&marketplace.id, nft_id)
    }

    /// Get listing price
    public fun listing_price(marketplace: &Marketplace<SUI>, nft_id: ID): u64 {
        // Check if the listing exists using DOF check
        assert!(is_listed(marketplace, nft_id), EListingNotFound);

        // We borrow the Listing object via DOF
        let listing = ofield::borrow<ID, Listing>(&marketplace.id, nft_id);
        listing.price
    }

    /// Get listing seller
    public fun listing_seller(marketplace: &Marketplace<SUI>, nft_id: ID): address {
        // Check if the listing exists using DOF check
        assert!(is_listed(marketplace, nft_id), EListingNotFound);

        // We borrow the Listing object via DOF
        let listing = ofield::borrow<ID, Listing>(&marketplace.id, nft_id);
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

#[test_only]
module nft::nft_marketplace_tests {
    use nft::nft_marketplace::{
        Self,
        NFT,
        Marketplace,
        Listing,
        ENotSeller,
        EInvalidPrice,
        EInsufficientPayment
    };
    use std::string;
    use sui::coin::{Self, Coin};
    use sui::id::ID;
    use sui::object;
    use sui::sui::SUI;
    use sui::test_scenario::{Self as ts, Scenario, ctx};

    // Helper function to create a new Coin<SUI>
    fun create_coin(amount: u64, ctx: &mut TxContext): Coin<SUI> {
        coin::mint_for_testing(amount, ctx)
    }

    // Helper function to take Marketplace
    fun get_marketplace(scenario: &Scenario): Marketplace<SUI> {
        ts::take_shared<Marketplace<SUI>>(scenario)
    }

    // Helper function to return Marketplace
    fun return_marketplace(scenario: &Scenario, marketplace: Marketplace<SUI>) {
        ts::return_shared(scenario, marketplace)
    }

    #[test]
    fun test_full_marketplace_flow() {
        let seller = @0xA;
        let buyer = @0xB;
        let publisher = @0xC;

        let mut scenario = ts::begin(publisher);

        // === Publisher: Init Marketplace ===
        ts::next_tx(&mut scenario, publisher);
        {
            nft_marketplace::init(ctx(&mut scenario));
        };

        // === Seller: Mint NFT ===
        let nft_id: ID = object::min_id(); // Placeholder, actual ID is generated in mint
        ts::next_tx(&mut scenario, seller);
        {
            nft_marketplace::mint(
                b"Sale NFT",
                b"NFT for testing sale",
                b"https://example.com/nft.png",
                ctx(&mut scenario),
            );

            // Get the newly minted NFT to read its ID
            let nft = ts::take_from_sender<NFT>(&scenario);
            nft_id = nft_marketplace::nft_id(&nft);
            ts::return_to_sender(&scenario, nft);
        };

        // === Seller: List NFT ===
        let list_price = 1000;
        ts::next_tx(&mut scenario, seller);
        {
            let mut marketplace = get_marketplace(&scenario);
            let nft = ts::take_from_sender<NFT>(&scenario);
            nft_marketplace::list(&mut marketplace, nft, list_price, ctx(&mut scenario));
            return_marketplace(&scenario, marketplace);
        };

        // === Buyer: Purchase NFT ===
        let payment_amount = 1050;
        ts::next_tx(&mut scenario, buyer);
        {
            let mut marketplace = get_marketplace(&scenario);
            let payment = create_coin(payment_amount, ctx(&mut scenario));

            // Should contain the listing
            assert!(nft_marketplace::listing_price(&marketplace, nft_id) == list_price, 0);

            nft_marketplace::buy_and_take(&mut marketplace, nft_id, payment, ctx(&mut scenario));

            // Check marketplace balance
            // Fee is 2% of 1000 = 20
            assert!(nft_marketplace::marketplace_balance(&marketplace) == 20, 1);

            return_marketplace(&scenario, marketplace);
        };

        // === Seller: Withdraw Profits ===
        ts::next_tx(&mut scenario, seller);
        {
            let mut marketplace = get_marketplace(&scenario);

            // Seller amount = 1000 - 20 = 980
            nft_marketplace::take_profits_and_keep(&mut marketplace, ctx(&mut scenario));

            // Verify Coin received by seller
            let seller_coin = ts::take_from_sender<Coin<SUI>>(&scenario);
            assert!(coin::value(&seller_coin) == 980, 2);
            coin::destroy_for_testing(seller_coin);

            return_marketplace(&scenario, marketplace);
        };

        // === Publisher: Withdraw Fees ===
        let fee_withdraw_amount = 20;
        ts::next_tx(&mut scenario, publisher);
        {
            let mut marketplace = get_marketplace(&scenario);

            nft_marketplace::withdraw_marketplace_fees(
                &mut marketplace,
                fee_withdraw_amount,
                publisher,
                ctx(&mut scenario),
            );

            // Verify Coin received by publisher
            let fee_coin = ts::take_from_sender<Coin<SUI>>(&scenario);
            assert!(coin::value(&fee_coin) == 20, 3);
            coin::destroy_for_testing(fee_coin);

            // Verify Marketplace balance is now 0
            assert!(nft_marketplace::marketplace_balance(&marketplace) == 0, 4);

            return_marketplace(&scenario, marketplace);
        };

        // === Buyer: Verify NFT Ownership ===
        ts::next_tx(&mut scenario, buyer);
        {
            let nft = ts::take_from_sender<NFT>(&scenario);
            assert!(string::as_bytes(nft_marketplace::name(&nft)) == b"Sale NFT", 5);

            // Buyer should have received 50 MIST in change (1050 paid - 1000 price)
            let change_coin = ts::take_from_sender<Coin<SUI>>(&scenario);
            assert!(coin::value(&change_coin) == 50, 6);

            ts::return_to_sender(&scenario, nft);
            coin::destroy_for_testing(change_coin);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotSeller)]
    fun test_delist_unauthorized() {
        let seller = @0xA;
        let interloper = @0xB;
        let publisher = @0xC;

        let mut scenario = ts::begin(publisher);

        // Init Marketplace
        ts::next_tx(&mut scenario, publisher);
        { nft_marketplace::init(ctx(&mut scenario)); };

        // Seller Mints NFT
        let nft_id: ID = object::min_id();
        ts::next_tx(&mut scenario, seller);
        {
            let nft = nft_marketplace::mint_composable(
                b"Test NFT",
                b"A test NFT",
                b"https://example.com/nft.png",
                ctx(&mut scenario),
            );
            nft_id = nft_marketplace::nft_id(&nft);
            transfer::public_transfer(nft, seller);
        };

        // Seller Lists NFT
        ts::next_tx(&mut scenario, seller);
        {
            let mut marketplace = get_marketplace(&scenario);
            let nft = ts::take_from_sender<NFT>(&scenario);
            nft_marketplace::list(&mut marketplace, nft, 100, ctx(&mut scenario));
            return_marketplace(&scenario, marketplace);
        };

        // Interloper Tries to Delist (Should Fail)
        ts::next_tx(&mut scenario, interloper);
        {
            let mut marketplace = get_marketplace(&scenario);
            nft_marketplace::delist_and_take<NFT, SUI>(
                &mut marketplace,
                nft_id,
                ctx(&ts::scenario_mut(&mut scenario)),
            );
            return_marketplace(&scenario, marketplace); // Will not reach here due to expected failure
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EInsufficientPayment)]
    fun test_buy_insufficient_payment() {
        let seller = @0xA;
        let buyer = @0xB;
        let publisher = @0xC;

        let mut scenario = ts::begin(publisher);

        // Init Marketplace
        ts::next_tx(&mut scenario, publisher);
        { nft_marketplace::init(ctx(&mut scenario)); };

        // Seller Mints and Lists NFT (Price 1000)
        let nft_id: ID = object::min_id();
        ts::next_tx(&mut scenario, seller);
        {
            let nft = nft_marketplace::mint_composable(
                b"NFT",
                b"A test NFT",
                b"",
                ctx(&mut scenario),
            );
            nft_id = nft_marketplace::nft_id(&nft);
            transfer::public_transfer(nft, seller);
        };
        ts::next_tx(&mut scenario, seller);
        {
            let mut marketplace = get_marketplace(&scenario);
            let nft = ts::take_from_sender<NFT>(&scenario);
            nft_marketplace::list(&mut marketplace, nft, 1000, ctx(&mut scenario));
            return_marketplace(&scenario, marketplace);
        };

        // Buyer Tries to Buy with less than 1000 (e.g., 500)
        ts::next_tx(&mut scenario, buyer);
        {
            let mut marketplace = get_marketplace(&scenario);
            let payment = create_coin(500, ctx(&mut scenario));
            nft_marketplace::buy_and_take<NFT, SUI>(
                &mut marketplace,
                nft_id,
                payment,
                ctx(&mut scenario),
            );
            // Cleanup in case of failure
            return_marketplace(&scenario, marketplace);
        };

        ts::end(scenario);
    }
}
