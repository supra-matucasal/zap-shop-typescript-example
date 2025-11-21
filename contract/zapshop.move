module ZAPSHOP::zap_shop_v1 {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::math64;
    use std::table::{Self as Table, Table};
    use supra_framework::timestamp;
    use supra_framework::randomness;
    use supra_framework::event;
    use supra_framework::coin;
    use supra_framework::account;
    use supra_framework::account::SignerCapability;
    use supra_framework::supra_account;
    use supra_addr::supra_vrf;
    use supra_addr::deposit::{Self, SupraVRFPermit};

    /********** COIN **********/
    struct ZAP has store, key, drop {}

    struct CoinCaps has key {
        mint_cap: coin::MintCapability<ZAP>,
        burn_cap: coin::BurnCapability<ZAP>,
        freeze_cap: coin::FreezeCapability<ZAP>
    }

    struct Treasury has key {
        addr: address
    }

    /********** CONSTANTS **********/
    const TIER_BRONZE: u8 = 1; // bronze
    const TIER_SILVER: u8 = 2; // silver
    const TIER_GOLD: u8 = 3; // gold

    const SLOT_M1: u8 = 1; // 1st month slot of crate opening
    const SLOT_M2: u8 = 2; //  2nd month slot of crate opening
    const SLOT_M3: u8 = 3; // 3rd month slot of crate opening

    // raffle tiers
    // tier A = 0
    const RAFFLE_TIER_A_TYPE1: u8 = 1;
    const RAFFLE_TIER_A_TYPE2: u8 = 2;
    const RAFFLE_TIER_A_TYPE3: u8 = 3;
    const RAFFLE_TIER_A_TYPE4: u8 = 4;
    // tier B = 1
    const RAFFLE_TIER_B_TYPE1: u8 = 11;
    // tier C = 2
    const RAFFLE_TIER_C_TYPE1: u8 = 21;
    const RAFFLE_TIER_C_TYPE2: u8 = 22;
    const RAFFLE_TIER_C_TYPE3: u8 = 23;
    // tier D = 3
    const RAFFLE_TIER_D_TYPE1: u8 = 31;
    const RAFFLE_TIER_D_TYPE2: u8 = 32;

    const SECS_PER_DAY: u64 = 86400;

    /********** CONFIG **********/
    struct Config has key {
        admin: address,
        season_start_ts: u64,
        season_end_ts: u64,
        crate_open_start_m1: u64,
        crate_open_start_m2: u64,
        crate_open_start_m3: u64,
        bronze_total: u64,
        silver_total: u64,
        gold_total: u64,
        bronze_per_day: u64,
        silver_per_day: u64,
        gold_per_day: u64,
        bronze_user_cap_per_day: u64,
        silver_user_cap_per_day: u64,
        gold_user_cap_per_day: u64,
        // raffle_total: u64,
        // raffle_per_day: u64,
        // raffle_user_cap_per_day: u64,
        raffle_price_A: u64,
        raffle_price_B: u64,
        raffle_price_C: u64,
        raffle_price_D: u64,

        // purchase prices chosen by (tier, month_slot)
        price_bronze_crate_m1: u64,
        price_bronze_crate_m2: u64,
        price_bronze_crate_m3: u64,
        price_silver_crate_m1: u64,
        price_silver_crate_m2: u64,
        price_silver_crate_m3: u64,
        price_gold_crate_m1: u64,
        price_gold_crate_m2: u64,
        price_gold_crate_m3: u64,
        crate_max_single_prize_supra: u64,
        zap_decimals: u8
    }

    // list of users who have registered
    // stored under admin
    struct UsersList has key {
        users: vector<address>,
        users_init_balance: Table<address, u64> // balance of each user
    }

    // Marker struct for vrf module registration
    struct MarkerVrf has store {}

    /// Capability struct that holds the VRF permit
    /// This permit authorizes this module to interact with Supra VRF
    struct PermitCap has key {
        permit: SupraVRFPermit<MarkerVrf>
    }

    // Struct to store nonces after requesting vrf randomness
    struct NonceEntry has key {
        raffle_nonce: Option<vector<u64>>,
        crate_nonce: Table<u64, u64>
    }

    // Struct to store raffle winners
    struct RaffleWinners has key {
        raffle_ids: vector<u64>, // unique raffle id which won
        winners_by_type_id: Table<u8, vector<address>>, // owners of the raffleids
        winners_by_tier: Table<u8, vector<address>>, // owners of the raffleids
        prize_supra: u64,
        is_prize_supra: bool, // TRUE --> supra coins // FALSE --> Physical prize
        nonce: u64
    }

    // Struct to store raffles under admin
    struct RafflesList has key {
        raffle_ids: vector<u64>, // all raffle ids sold
        raffle_id_user: Table<u64, address>, // unique raffle_id -> user address
        raffle_ids_by_type: Table<u8, vector<u64>> // type_id -> list of raffle_ids
    }

    /********** INVENTORY **********/
    /// Stored crate instance under user inventory
    struct Crate has store, copy {
        id: u64,
        owner: address,
        tier: u8,
        month_slot: u8,
        unlock_ts: u64,
        price: u64,
        purchased_ts: u64,
        opened: bool,
        opened_ts: Option<u64>,
        prize: Option<u64>,
        is_prize_claimed: bool
    }

    /// Global crate table (under admin)
    struct CrateTable has key {
        crate_owner: Table<u64, address> // crate_id -> owner
    }

    /// Merchandise TYPE stored in MerchTable under admin
    struct Merch has store, drop, copy {
        id: u64,
        name: String,
        price: u64, // in ZAP base units
        total_supply: u64, // fixed stock
        sold: u64 // total sold so far
    }

    /// Global merchandise type table (under admin)
    struct MerchTable has key {
        items: Table<u64, Merch>, // merch_type_id -> Merch
        type_ids: vector<u64> // list of all merch_type_ids
    }

    /// User inventory (under each user)
    struct Inventory has key {
        raffle_ids: vector<u64>,
        crates: Table<u64, Crate>,
        crate_ids: vector<u64>,
        merch: Table<u64, UserMerch>, // merch_type_id -> UserMerch
        merch_type_ids: vector<u64>
    }

    /// User merchandise details of purchase, inside inventory struct
    struct UserMerch has store, drop, copy {
        type_id: u64,
        quantity: u64,
        price: u64,
        purchase_time: u64
    }

    /********** COUNTERS **********/
    /// Global sequential counters for items sold (stored under admin)
    struct Counters has key {
        raffle_counter: u64,
        crate_counter: u64
    }

    /// Global totals across the season (needed for carry-forward checks) (stored under admin)
    struct GlobalTotals has key {
        raffle_sold_total: u64,
        bronze_sold_total: u64,
        silver_sold_total: u64,
        gold_sold_total: u64
    }

    /// Global per-day counters (stored under admin)
    struct GlobalDayCounters has key {
        raffle_sold: Table<u64, u64>, // day_index -> qty sold that day
        bronze_sold: Table<u64, u64>,
        silver_sold: Table<u64, u64>,
        gold_sold: Table<u64, u64>
    }

    /// Per-user daily counters (stored under each user)
    struct UserDayCounters has key {
        per_day: Table<u64, DailyUser> // day_index -> DailyUser
    }

    /// Daily purchase counts per user
    struct DailyUser has store, copy {
        raffles: u64,
        bronze: u64,
        silver: u64,
        gold: u64
    }

    /// NEW: Global merchandise sales trackers
    struct MerchCounters has key {
        total_merch_sold: Table<u64, u64>, // merch_type_id -> qty sold so far u64,
        daily_merch_sold: Table<u64, u64>, // composite key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + day_index
        window_merch_sold: Table<u64, u64> // composite key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + window_index
    }

    /// NEW: Per-user merchandise cap tracker
    struct UserMerchCap has key {
        bought_merch: Table<u64, bool> // merch_type_id -> true if already purchased once
    }

    /********** EVENTS **********/
    struct Events has key {
        user_registered: event::EventHandle<UserRegistered>,
        raffle_purchased: event::EventHandle<RafflesPurchased>,
        crate_purchased: event::EventHandle<CratePurchased>,
        crate_opened: event::EventHandle<CrateOpened>,
        crate_prize_claimed: event::EventHandle<CratePrizeClaimed>,
        merch_purchased: event::EventHandle<MerchPurchased>,
        merch_type_added: event::EventHandle<MerchTypeAdded>,
        raffle_winner_picked: event::EventHandle<RaffleWinnerPicked>
    }

    #[event]
    struct UserRegistered has drop, store {
        user: address,
        zap_balance: u64,
        timestamp: u64
    }

    #[event]
    struct RafflesPurchased has drop, store {
        user: address,
        raffle_ids: vector<u64>,
        raffle_type_id: u8,
        paid_zap: u64,
        timestamp: u64
    }

    #[event]
    struct CratePurchased has drop, store {
        user: address,
        crate_id: u64,
        tier: u8,
        month_slot: u8,
        paid_zap: u64,
        timestamp: u64
    }

    #[event]
    struct CrateOpened has drop, store {
        user: address,
        crate_id: u64,
        tier: u8,
        prize_supra_alloted: u64,
        timestamp: u64,
        month_slot: u8
    }

    #[event]
    struct MerchPurchased has drop, store {
        user: address,
        merch_type_id: u64,
        quantity: u64,
        paid_zap: u64,
        timestamp: u64
    }

    #[event]
    struct MerchTypeAdded has drop, store {
        merch_type_id: u64,
        name: String,
        price: u64,
        total_supply: u64,
        timestamp: u64
    }

    #[event]
    struct RaffleWinnerPicked has drop, store {
        raffle_ids: vector<u64>,
        winners: vector<address>,
        type_id: u8,
        timestamp: u64
    }

    #[event]
    struct CratePrizeClaimed has drop, store {
        user: address,
        crate_id: u64,
        prize_supra_claimed: u64,
        timestamp: u64
    }

    /********** FOR VRF RANDOMNESS **********/
    const RESOURCE_ADDRESS_SEED: vector<u8> = b"ResourceSignerCap";
    const SUPRA_DECIMALS: u64 = 100000000; // 10^8
    const MERCH_TYPE_ID_MULTIPLIER: u64 = 100000000; // 10^8
    const CRATE_TIER_MULTIPLIER: u64 = 1_000_000_0000; // 10^10
    const CRATE_MONTH_SLOT_MULTIPLIER: u64 = 1_000_0000; // 10^7

    /// Store Resource signer cap which is used as owner account which we ask supra admin to whitelist
    struct ResourceSignerCap has key {
        signer_cap: SignerCapability
    }

    struct RandomNumberList has key {
        list: Table<u64, vector<u256>> // nonce -> list of random numbers
    }

    /********** ERRORS **********/
    const E_NOT_ADMIN: u64 = 1000;
    const E_ONLY_ADMIN_PRIVILEDGE: u64 = 1001;
    const E_USER_NOT_REGISTERED: u64 = 1002;
    const E_INVALID_ARGUMENT: u64 = 1003;
    const E_MERCH_TYPE_DOESNT_EXIST: u64 = 1004;
    const E_PURCHASE_SUPPLY_EXCEEDED: u64 = 1005;
    const E_UNLOCK_TOO_EARLY: u64 = 1006;
    const E_CRATE_ALREADY_OPENED: u64 = 1007;
    const E_OUT_OF_SALE_WINDOW_PERIOD: u64 = 1008;
    const E_USER_ALREADY_INITIATED: u64 = 1009;
    const E_USER_NOT_INITIATED: u64 = 1025;

    const E_GLOBAL_LIMIT: u64 = 1010; // exceeded cumulative allowed (carry-forward)
    const E_USER_DAILY_LIMIT: u64 = 1011; // exceeded per-user daily cap
    const E_GLOBAL_DAILY_OVERFLOW: u64 = 1012; // overflow safety
    const E_NONCE_NOT_GENERATED_FOR_RAFFLE: u64 = 1013;
    const E_NONCE_NOT_ASSIGNED_FOR_CRATE: u64 = 1014;
    const E_INSUFFICIENT_BALANCE: u64 = 1015;
    const E_USER_DAILY_LIMIT_BRONZE_CRATE: u64 = 1016;
    const E_USER_DAILY_LIMIT_SILVER_CRATE: u64 = 1017;
    const E_USER_DAILY_LIMIT_GOLD_CRATE: u64 = 1018;
    const E_MERCH_DAILY_LIMIT_CROSSED: u64 = 1019;
    const E_MERCH_HOUR_WINDOW_LIMIT_CROSSED: u64 = 1020;
    const E_USER_DOESNT_OWN_THIS_CRATE: u64 = 1021;
    const E_USER_MERCH_CAP_CROSSED: u64 = 1022;
    const E_CRATE_NOT_YET_OPENED: u64 = 1023;
    const E_CRATE_PRIZE_ALREADY_CLAIMED: u64 = 1024;

    /********** INIT **********/
    /// Initializes the ZapShop module and deploys all core global resources.
    ///
    /// This function must be called once by the admin (ZAPSHOP address)
    /// to bootstrap all persistent resources required by the system.
    ///
    /// It creates and publishes the following resources under the admin:
    /// - `Treasury`: holds the admin address for all deposits.
    /// - `UsersList`: maintains the list of all registered users.
    /// - `ResourceSignerCap`: a capability for creating a resource account
    ///   used for VRF integration (whitelisted by Supra).
    /// - `RandomNumberList`: stores nonce --> random number mappings for VRF responses.
    /// - `RafflesList`, `RaffleWinners`, `NonceEntry`: track raffles, winners, and randomness nonces.
    /// - `MerchTable`: registry for all merchandise types.
    /// - `Counters`: sequential IDs for crates and raffles.
    /// - `MerchCounters`: tracks total/daily/hourly merchandise sales.
    /// - `GlobalTotals`, `GlobalDayCounters`: global crate and raffle sales counters.
    /// - `Events`: initializes all event handles for purchases and draws.
    ///
    /// Emits no events.
    ///
    /// # Access
    /// Must be called by the admin only during deployment.
    /// # Aborts with:
    /// - none directly (expected to be first initialization).
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        move_to(admin, Treasury { addr: admin_addr });
        move_to(
            admin,
            UsersList {
                users: vector::empty(),
                users_init_balance: Table::new()
            }
        );
        let (_resource_signer, signer_cap) =
            account::create_resource_account(admin, RESOURCE_ADDRESS_SEED);
        move_to(admin, ResourceSignerCap { signer_cap });
        move_to(admin, RandomNumberList { list: Table::new() });
        move_to(
            admin,
            RafflesList {
                raffle_ids: vector::empty<u64>(),
                raffle_id_user: Table::new(),
                raffle_ids_by_type: Table::new()
            }
        );
        move_to(
            admin,
            NonceEntry {
                raffle_nonce: option::none<vector<u64>>(),
                crate_nonce: Table::new()
            }
        );
        move_to(
            admin,
            RaffleWinners {
                raffle_ids: vector::empty<u64>(),
                winners_by_type_id: Table::new(),
                winners_by_tier: Table::new(),
                prize_supra: 0,
                is_prize_supra: false,
                nonce: 0
            }
        );

        move_to(
            admin,
            MerchTable {
                items: Table::new(),
                type_ids: vector::empty()
            }
        );
        move_to(admin, Counters { raffle_counter: 0, crate_counter: 0 });
        move_to(
            admin,
            MerchCounters {
                total_merch_sold: Table::new(),
                daily_merch_sold: Table::new(),
                window_merch_sold: Table::new()
            }
        );
        // NEW: global totals & per-day tables
        move_to(
            admin,
            GlobalTotals {
                raffle_sold_total: 0,
                bronze_sold_total: 0,
                silver_sold_total: 0,
                gold_sold_total: 0
            }
        );
        move_to(
            admin,
            GlobalDayCounters {
                raffle_sold: Table::new(),
                bronze_sold: Table::new(),
                silver_sold: Table::new(),
                gold_sold: Table::new()
            }
        );

        move_to(admin, CrateTable { crate_owner: Table::new() });

        move_to(
            admin,
            Events {
                user_registered: account::new_event_handle<UserRegistered>(admin),
                raffle_purchased: account::new_event_handle<RafflesPurchased>(admin),
                crate_purchased: account::new_event_handle<CratePurchased>(admin),
                crate_opened: account::new_event_handle<CrateOpened>(admin),
                crate_prize_claimed: account::new_event_handle<CratePrizeClaimed>(admin),
                merch_purchased: account::new_event_handle<MerchPurchased>(admin),
                merch_type_added: account::new_event_handle<MerchTypeAdded>(admin),
                raffle_winner_picked: account::new_event_handle<RaffleWinnerPicked>(admin)
            }
        );
    }

    /// Initializes the season configuration and coin parameters for the module.
    ///
    /// This function sets all season parameters including sale start/end times,
    /// crate unlock schedules, daily caps, user caps, and pricing for crates and raffles.
    ///
    /// It also initializes the ZAP coin with mint, burn, and freeze capabilities
    /// and stores those capabilities in `CoinCaps` for later mint/burn usage.
    ///
    /// Registers the ZAP coin under the admins account.
    ///
    /// # Parameters
    /// - `season_start_ts`: timestamp when the sales season begins.
    /// - `season_end_ts`: timestamp when the season ends.
    /// - `open_m1`, `open_m2`, `open_m3`: unlock times for each crate slot (month-wise).
    /// - `decimals`: number of decimals for ZAP token (e.g. 6 or 8).
    ///
    /// # Access
    /// Only the admin address (`@ZAPSHOP`) may call this function.
    ///
    /// # Aborts with:
    /// - `E_NOT_ADMIN` if caller is not the admin.
    public entry fun initialize(
        admin: &signer,
        season_start_ts: u64,
        season_end_ts: u64,
        open_m1: u64,
        open_m2: u64,
        open_m3: u64,
        decimals: u8
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(@ZAPSHOP == admin_addr, E_NOT_ADMIN);

        move_to(
            admin,
            Config {
                admin: admin_addr,
                season_start_ts,
                season_end_ts,
                crate_open_start_m1: open_m1,
                crate_open_start_m2: open_m2,
                crate_open_start_m3: open_m3,
                bronze_total: 39_000,
                silver_total: 6_000,
                gold_total: 760,
                bronze_per_day: 2785,
                silver_per_day: 428,
                gold_per_day: 54,
                bronze_user_cap_per_day: 4,
                silver_user_cap_per_day: 2,
                gold_user_cap_per_day: 1,
                raffle_price_A: 10_000_000, // example: 10 ZAP at 6 decimals => 10_000_000
                raffle_price_B: 10_000_000, // 10 ZAP
                raffle_price_C: 2_000_000, // 2 ZAP
                raffle_price_D: 2_000_000, // 2 ZAP
                price_bronze_crate_m1: 50_000_000, // 50 ZAP
                price_bronze_crate_m2: 30_000_000, // 30 ZAP
                price_bronze_crate_m3: 10_000_000, // 10 ZAP
                price_silver_crate_m1: 200_000_000, // 200 ZAP
                price_silver_crate_m2: 80_000_000, // 80 ZAP
                price_silver_crate_m3: 40_000_000, // 40 ZAP
                price_gold_crate_m1: 500_000_000, // 500 ZAP
                price_gold_crate_m2: 300_000_000, // 300 ZAP
                price_gold_crate_m3: 100_000_000, // 100 ZAP
                crate_max_single_prize_supra: 80_000, //   (80_000 Supra)
                zap_decimals: decimals
            }
        );

        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<ZAP>(
                admin,
                string::utf8(b"ZAP Coin"),
                string::utf8(b"ZAP"),
                decimals,
                true
            );

        coin::register<ZAP>(admin);

        move_to(
            admin,
            CoinCaps { mint_cap, burn_cap, freeze_cap }
        );
    }

    /********** WHITELIST CONTRACTED USER FOR VRF **********/
    /// Adds this contract (ZAPSHOP::zap_shop_v1) to Supra VRF whitelist.
    ///
    /// This allows the contract to request verifiable random numbers from Supra.
    /// A small Supra token deposit is made to enable VRF functionality.
    ///
    /// Creates and stores a `PermitCap` containing the VRF permit
    /// which will later be used for randomness requests.
    ///
    /// # Parameters
    /// - `amount`: number of Supra tokens to deposit for VRF usage.
    ///
    /// # Access
    /// Only the admin (`@ZAPSHOP`) can whitelist this contract.
    ///
    /// # Aborts with:
    /// - `E_NOT_ADMIN` if caller is not the admin.
    public entry fun add_contract_to_vrf_whitelist(
        admin: &signer, amount: u64
    ) {
        let admin_addr = signer::address_of(admin);
        assert!(@ZAPSHOP == admin_addr, E_NOT_ADMIN);
        deposit::whitelist_client_address(admin, 1_000_000); // 0.01 supra tokens
        let permit = deposit::init_vrf_module<MarkerVrf>(admin);
        deposit::deposit_fund_v2(admin, signer::address_of(admin), amount);

        move_to(admin, PermitCap { permit });

    }

    /********** USER REG **********/
    /// Registers a user for ZapShop and prepares all per-user resources.
    ///
    /// Creates (if missing):
    /// - `Inventory` (stores raffles, crates, and merch balances)
    /// - `UserDayCounters` (per-day purchase caps)
    /// - `UserMerchCap` (season cap: at most 1 per merch type)
    ///
    /// Also appends the user to the global `UsersList` and optionally
    /// mints ZAP to the user for testing/demo purposes if their ZAP
    /// account is not registered yet.
    ///
    /// # Parameters
    /// - `zap_balance`: if the users ZAP account is new, this many ZAP are minted to them (test bootstrap).
    ///
    /// # Effects
    /// - Publishes resources under the user if they dont exist.
    /// - Optionally mints and deposits ZAP into the users account.
    ///
    /// # Aborts with:
    /// - `E_USER_NOT_REGISTERED` is NOT thrown here; this function creates the registration.
    /// - Any `coin::register` or mint/deposit aborts if something goes wrong.
    public entry fun register_user(user: &signer) acquires UsersList, CoinCaps, Config, Events {
        let addr = signer::address_of(user);
        let ul = borrow_global_mut<UsersList>(admin_addr());
        if (!vector::contains(&ul.users, &addr)) {
            vector::push_back(&mut ul.users, addr);
        } else {
            // already registered, no-operation
            return
        };
        if (!exists<Inventory>(addr)) {
            move_to(
                user,
                Inventory {
                    raffle_ids: vector::empty<u64>(),
                    crates: Table::new(),
                    crate_ids: vector::empty<u64>(),
                    merch: Table::new(),
                    merch_type_ids: vector::empty<u64>()
                }
            );
        };
        if (!exists<UserDayCounters>(addr)) {
            move_to(user, UserDayCounters { per_day: Table::new() });
        };
        if (!exists<UserMerchCap>(addr)) {
            move_to(user, UserMerchCap { bought_merch: Table::new() });
        };

        assert!(Table::contains(&ul.users_init_balance, addr), E_USER_NOT_INITIATED);
        let zap_balance = *Table::borrow(&ul.users_init_balance, addr);

        if (!coin::is_account_registered<ZAP>(addr)) {
            coin::register<ZAP>(user);
            let caps = borrow_global_mut<CoinCaps>(admin_addr());
            let minted_coins = coin::mint<ZAP>(zap_balance, &caps.mint_cap);
            coin::deposit(addr, minted_coins);
        };
        let cfg = borrow_global<Config>(admin_addr());
        let now = timestamp::now_seconds();
        event::emit_event<UserRegistered>(
            &mut borrow_global_mut<Events>(cfg.admin).user_registered,
            UserRegistered { user: addr, zap_balance, timestamp: now }
        );
    }

    public entry fun user_init_zap_snapshot(
        admin: &signer, user: address, zap_balance: u64
    ) acquires UsersList {
        let admin_addr = signer::address_of(admin);
        assert!(@ZAPSHOP == admin_addr, E_NOT_ADMIN);
        let us = borrow_global_mut<UsersList>(admin_addr());
        assert!(
            !Table::contains(&us.users_init_balance, user), E_USER_ALREADY_INITIATED
        );
        Table::add(&mut us.users_init_balance, user, zap_balance);
    }

    /// Mints and funds a given user account with ZAP tokens (temporary helper).
    ///
    /// This function exists for testing and development only. It allows
    /// the admin to mint ZAP coins and deposit them into a users account.
    ///
    /// # Parameters
    /// - `user`: target address to receive minted coins.
    /// - `amount`: number of ZAP coins to mint.
    ///
    /// # Access
    /// Admin only (validated via `ensure_admin`).
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin calls it.
    public entry fun fund_user_temporary(
        admin: &signer, user: address, amount: u64
    ) acquires CoinCaps, Config {
        ensure_admin(admin);
        let caps = borrow_global_mut<CoinCaps>(signer::address_of(admin)); // ensure admin
        if (!coin::is_account_registered<ZAP>(user)) {
            assert!(false, E_USER_NOT_REGISTERED);
        };
        let minted_coins = coin::mint<ZAP>(amount, &caps.mint_cap);
        coin::deposit(user, minted_coins);
    }

    /// Ensures a given address is registered as a ZapShop user.
    ///
    /// Verifies that `Inventory` exists under the user and the user is present
    /// in the global `UsersList`. Intended as a guard before purchase flows.
    ///
    /// # Aborts with:
    /// - `E_USER_NOT_REGISTERED` if user is not registered.
    public fun has_registered(user: address) acquires UsersList {
        let ul = borrow_global_mut<UsersList>(admin_addr());
        assert!(
            exists<Inventory>(user) && vector::contains(&ul.users, &user),
            E_USER_NOT_REGISTERED
        );
    }

    /********** ADMIN: MERCH SETUP **********/
    /// Adds or updates a merchandise type in the global `MerchTable`.
    ///
    /// If the `merch_type_id` already exists, updates its `name`, `price`,
    /// and `total_supply` while preserving the existing `sold` count.
    /// Otherwise, inserts a new `Merch`.
    ///
    /// # Parameters
    /// - `merch_type_id`: unique ID for this merchandise type.
    /// - `name`: display name.
    /// - `price`: unit price in ZAP base units.
    /// - `total_supply`: max available inventory for the entire season.
    ///
    /// # Access
    /// Admin only.
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin calls it.
    public entry fun add_merch_merch_type(
        admin: &signer,
        merch_type_id: u64,
        name: String,
        price: u64,
        total_supply: u64
    ) acquires MerchTable, Config, Events {
        let cfg = borrow_global<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);

        let mt = borrow_global_mut<MerchTable>(cfg.admin);
        if (!vector::contains(&mt.type_ids, &merch_type_id)) {
            vector::push_back(&mut mt.type_ids, merch_type_id);
        };
        if (Table::contains(&mt.items, merch_type_id)) {
            let m = Table::borrow_mut(&mut mt.items, merch_type_id);
            // preserve sold; update fields
            m.name = name;
            m.price = price;
            m.total_supply = total_supply;
        } else {
            let item = Merch { id: merch_type_id, name, price, total_supply, sold: 0 };
            Table::add(&mut mt.items, merch_type_id, item);
        };
        let now = timestamp::now_seconds();
        event::emit_event<MerchTypeAdded>(
            &mut borrow_global_mut<Events>(cfg.admin).merch_type_added,
            MerchTypeAdded { merch_type_id, name, price, total_supply, timestamp: now }
        );
    }

    /********** BUY RAFFLE (carry-forward + per-user daily) **********/
    /// Purchases raffle tickets of a specific `type_id` within the season window.
    ///
    /// Pricing tiers:
    /// - Types {1,2,3,4} --> `raffle_price_A`
    /// - Types {11} --> `raffle_price_B`
    /// - Types {21,22,23} --> `raffle_price_C`
    /// - Types {31,32} --> `raffle_price_D`
    ///
    /// Effects:
    /// - Charges the total price via `pay`
    /// - Increments global totals (`GlobalTotals`, `GlobalDayCounters`) and user daily counts
    /// - Mints unique raffle IDs encoding `type_id` and a global sequence
    /// - Records ownership in `RafflesList` and in the users `Inventory`
    /// - Emits `RafflesPurchased` with all purchased IDs
    ///
    /// # Aborts with:
    /// - `E_USER_NOT_REGISTERED` if caller is not registered
    /// - `E_INVALID_ARGUMENT` if `type_id` is unsupported
    /// - `E_INSUFFICIENT_BALANCE` via `pay` if insufficient ZAP
    public entry fun buy_raffles(
        user: &signer, quantity: u64, type_id: u8
    ) acquires Counters, Events, Inventory, Config, Treasury, UsersList, GlobalTotals, GlobalDayCounters, UserDayCounters, RafflesList {
        let user_addr = signer::address_of(user);
        assert!(quantity > 0, E_INVALID_ARGUMENT);
        has_registered(user_addr);
        let now = ensure_in_window();
        let cfg = borrow_global<Config>(admin_addr());
        let day = day_index(cfg.season_start_ts, now);

        let totals = borrow_global_mut<GlobalTotals>(cfg.admin);
        let global = borrow_global_mut<GlobalDayCounters>(cfg.admin);
        let sold_today_ptr = get_or_init_u64(&mut global.raffle_sold, day);

        let userc = borrow_global_mut<UserDayCounters>(user_addr);
        let du = get_or_init_user(&mut userc.per_day, day);
        let price: u64;
        if (type_id == RAFFLE_TIER_A_TYPE1
            || type_id == RAFFLE_TIER_A_TYPE2
            || type_id == RAFFLE_TIER_A_TYPE3
            || type_id == RAFFLE_TIER_A_TYPE4) {
            price = cfg.raffle_price_A * quantity;
        } else if (type_id == RAFFLE_TIER_B_TYPE1) {
            price = cfg.raffle_price_B * quantity;
        } else if (type_id == RAFFLE_TIER_C_TYPE1
            || type_id == RAFFLE_TIER_C_TYPE2
            || type_id == RAFFLE_TIER_C_TYPE3) {
            price = cfg.raffle_price_C * quantity;
        } else if (type_id == RAFFLE_TIER_D_TYPE1 || type_id == RAFFLE_TIER_D_TYPE2) {
            price = cfg.raffle_price_D * quantity;
        } else {
            price = 0;
            abort E_INVALID_ARGUMENT
        };

        pay(user, price);

        // apply effects
        totals.raffle_sold_total = totals.raffle_sold_total + quantity;
        *sold_today_ptr = *sold_today_ptr + quantity; // (purely informational; not required for carry-forward)
        du.raffles = du.raffles + quantity;

        // existing purchase effects
        let counters = borrow_global_mut<Counters>(cfg.admin);
        let inv = borrow_global_mut<Inventory>(user_addr);
        let raffles_list = borrow_global_mut<RafflesList>(cfg.admin);
        let i = quantity;
        let purchased_raffle_ids = vector::empty<u64>();
        while (i > 0) {
            counters.raffle_counter = counters.raffle_counter + 1;
            let raffle_id = ((100000000000000u64 * (type_id as u64))
                + counters.raffle_counter);
            vector::push_back(&mut purchased_raffle_ids, raffle_id);
            vector::push_back(&mut raffles_list.raffle_ids, raffle_id);
            Table::add(&mut raffles_list.raffle_id_user, raffle_id, user_addr);
            if (!Table::contains(&raffles_list.raffle_ids_by_type, type_id)) {
                Table::add(
                    &mut raffles_list.raffle_ids_by_type, type_id, vector::empty<u64>()
                );
            };
            let raffles_by_type =
                Table::borrow_mut(&mut raffles_list.raffle_ids_by_type, type_id);
            vector::push_back(raffles_by_type, raffle_id);
            vector::push_back(&mut inv.raffle_ids, raffle_id);
            i = i - 1;
        };

        event::emit_event<RafflesPurchased>(
            &mut borrow_global_mut<Events>(cfg.admin).raffle_purchased,
            RafflesPurchased {
                user: user_addr,
                raffle_ids: purchased_raffle_ids,
                raffle_type_id: type_id,
                paid_zap: price,
                timestamp: now
            }
        );
    }

    /********** BUY CRATE (tier + month_slot) with carry-forward + per-user daily **********/
    /// Buys multiple crates of a given `tier` and `month_slot` in one call.
    ///
    /// Internally calls `buy_single_crate` in a loop (`quantity` times),
    /// enforcing all global/user caps and pricing per crate.
    ///
    /// # Aborts with:
    /// - Any aborts from `buy_single_crate`
    /// - `E_USER_NOT_REGISTERED` if user not registered
    public entry fun buy_crates(
        user: &signer,
        tier: u8,
        month_slot: u8,
        quantity: u8
    ) acquires Counters, Events, Inventory, Config, Treasury, UsersList, GlobalTotals, GlobalDayCounters, UserDayCounters, CrateTable {
        assert!(quantity > 0, E_INVALID_ARGUMENT);
        let user_addr = signer::address_of(user);
        has_registered(user_addr);
        let now = ensure_in_window();

        assert!(
            (tier == TIER_BRONZE || tier == TIER_SILVER || tier == TIER_GOLD),
            E_INVALID_ARGUMENT
        );

        assert!(
            (month_slot == SLOT_M1
                || month_slot == SLOT_M2
                || month_slot == SLOT_M3),
            E_INVALID_ARGUMENT
        );

        let i: u8 = 0;
        while (i < quantity) {
            buy_single_crate(user, tier, month_slot, now);
            i = i + 1;
        };
    }

    /// Buys a single crate and updates all relevant counters atomically.
    ///
    /// Enforces:
    /// - Season window and day index
    /// - Global carry-forward limit by tier (`bronze/silver/gold_total` & `_per_day`)
    /// - Per-user daily cap by tier (bronze/silver/gold)
    /// - Price determined by `(tier, month_slot)`
    ///
    /// Effects:
    /// - Charges ZAP via `pay`
    /// - Mints a unique `crate_id` that encodes (tier, slot, sequence)
    /// - Adds crate to user `Inventory` with unlock time based on slot
    /// - Updates global and per-user counters
    /// - Emits `CratePurchased`
    ///
    /// # Aborts with:
    /// - `E_GLOBAL_LIMIT` if cumulative sold would exceed allowed carry-forward
    /// - `E_USER_DAILY_LIMIT_*` if user exceeds per-day cap
    /// - `E_INVALID_ARGUMENT` if invalid tier/slot combination
    /// - `E_INSUFFICIENT_BALANCE` via `pay`
    fun buy_single_crate(
        user: &signer,
        tier: u8,
        month_slot: u8,
        now: u64
    ) acquires Inventory, Events, Treasury, Config, Counters, GlobalTotals, GlobalDayCounters, UserDayCounters, CrateTable {
        let cfg = borrow_global<Config>(admin_addr());
        let day = day_index(cfg.season_start_ts, now);
        let user_addr = signer::address_of(user);

        // choose tables/caps by tier
        let totals = borrow_global_mut<GlobalTotals>(cfg.admin);
        let global = borrow_global_mut<GlobalDayCounters>(cfg.admin);
        let (sold_total_ptr, sold_today_tbl, per_day_cap, total_cap) =
            if (tier == TIER_BRONZE) {
                (
                    &mut totals.bronze_sold_total,
                    &mut global.bronze_sold,
                    cfg.bronze_per_day,
                    cfg.bronze_total
                )
            } else if (tier == TIER_SILVER) {
                (
                    &mut totals.silver_sold_total,
                    &mut global.silver_sold,
                    cfg.silver_per_day,
                    cfg.silver_total
                )
            } else {
                (
                    &mut totals.gold_sold_total,
                    &mut global.gold_sold,
                    cfg.gold_per_day,
                    cfg.gold_total
                )
            };

        // cumulative allowed to have been sold (carry-forward)
        let allowed_cum = math64::min(total_cap, (day + 1) * per_day_cap);
        assert!(
            *sold_total_ptr + 1 <= allowed_cum,
            E_GLOBAL_LIMIT
        );

        // per-user daily cap (by tier)
        let userc = borrow_global_mut<UserDayCounters>(user_addr);
        let du = get_or_init_user(&mut userc.per_day, day);
        if (tier == TIER_BRONZE) {
            assert!(
                du.bronze + 1 <= cfg.bronze_user_cap_per_day,
                E_USER_DAILY_LIMIT_BRONZE_CRATE
            );
        } else if (tier == TIER_SILVER) {
            assert!(
                du.silver + 1 <= cfg.silver_user_cap_per_day,
                E_USER_DAILY_LIMIT_SILVER_CRATE
            );
        } else if (tier == TIER_GOLD) {
            assert!(
                du.gold + 1 <= cfg.gold_user_cap_per_day,
                E_USER_DAILY_LIMIT_GOLD_CRATE
            );
        };

        // charge price by (tier, month_slot)
        let price =
            if (tier == TIER_BRONZE && month_slot == SLOT_M1) {
                cfg.price_bronze_crate_m1
            } else if (tier == TIER_BRONZE && month_slot == SLOT_M2) {
                cfg.price_bronze_crate_m2
            } else if (tier == TIER_BRONZE && month_slot == SLOT_M3) {
                cfg.price_bronze_crate_m3
            } else if (tier == TIER_SILVER && month_slot == SLOT_M1) {
                cfg.price_silver_crate_m1
            } else if (tier == TIER_SILVER && month_slot == SLOT_M2) {
                cfg.price_silver_crate_m2
            } else if (tier == TIER_SILVER && month_slot == SLOT_M3) {
                cfg.price_silver_crate_m3
            } else if (tier == TIER_GOLD && month_slot == SLOT_M1) {
                cfg.price_gold_crate_m1
            } else if (tier == TIER_GOLD && month_slot == SLOT_M2) {
                cfg.price_gold_crate_m2
            } else if (tier == TIER_GOLD && month_slot == SLOT_M3) {
                cfg.price_gold_crate_m3
            } else {
                abort(E_INVALID_ARGUMENT);
                0
            };

        pay(user, price);

        // mint crate: unique id that encodes tier+slot + sequence
        let counters = borrow_global_mut<Counters>(cfg.admin);
        counters.crate_counter = counters.crate_counter + 1;
        let crate_id =
            (tier as u64) * CRATE_TIER_MULTIPLIER
                + (month_slot as u64) * CRATE_MONTH_SLOT_MULTIPLIER
                + counters.crate_counter;

        let unlock_ts =
            if (month_slot == SLOT_M1) cfg.crate_open_start_m1
            else if (month_slot == SLOT_M2) cfg.crate_open_start_m2
            else cfg.crate_open_start_m3;

        let c = Crate {
            id: crate_id,
            owner: user_addr,
            tier,
            month_slot,
            price,
            purchased_ts: now,
            unlock_ts,
            opened: false,
            opened_ts: option::none<u64>(),
            prize: option::none<u64>(),
            is_prize_claimed: false
        };
        let inv = borrow_global_mut<Inventory>(user_addr);
        Table::add(&mut inv.crates, crate_id, c);
        vector::push_back(&mut inv.crate_ids, crate_id);

        // update counters AFTER success
        let sold_today_ptr = get_or_init_u64(sold_today_tbl, day);
        *sold_total_ptr = *sold_total_ptr + 1;
        *sold_today_ptr = *sold_today_ptr + 1;
        assert!(*sold_today_ptr >= 1, E_GLOBAL_DAILY_OVERFLOW);

        let d = get_or_init_user(&mut userc.per_day, day);
        if (tier == TIER_BRONZE) {
            d.bronze = d.bronze + 1;
        } else if (tier == TIER_SILVER) {
            d.silver = d.silver + 1;
        } else {
            d.gold = d.gold + 1;
        };

        let ct = borrow_global_mut<CrateTable>(admin_addr());
        Table::add(&mut ct.crate_owner, crate_id, user_addr);

        event::emit_event<CratePurchased>(
            &mut borrow_global_mut<Events>(cfg.admin).crate_purchased,
            CratePurchased {
                user: user_addr,
                crate_id,
                tier,
                month_slot,
                paid_zap: price,
                timestamp: now
            }
        );
    }

    /********** UPDATED BUY MERCH **********/
    /// Purchases one unit of a given merchandise type during the season window.
    ///
    /// Enforces:
    /// - Season window (`ensure_in_window`)
    /// - Quantity must be exactly 1 (per call)
    /// - Per-user season cap: at most 1 unit per merch type
    /// - Global daily cap with carry-forward (100/day)
    /// - Global 6-hour window cap with carry-forward (25/window)
    /// - Total stock limit (`total_supply`)
    ///
    /// On success:
    /// - Charges ZAP via `pay`
    /// - Updates `MerchCounters` (total, daily, window)
    /// - Sets users `UserMerchCap` for that `merch_type_id`
    /// - Updates user `Inventory`
    /// - Emits `MerchPurchased` event
    ///
    /// # Aborts with:
    /// - `E_INVALID_ARGUMENT` if `quantity == 0`
    /// - `E_USER_DAILY_LIMIT` if trying to buy more than 1 per call or user already purchased this type
    /// - `E_MERCH_TYPE_DOESNT_EXIST` if merch type is unknown
    /// - `E_MERCH_HOUR_WINDOW_LIMIT_CROSSED` if exceeds 6-hour carry-forward cap
    /// - `E_PURCHASE_SUPPLY_EXCEEDED` if surpassing total supply
    /// - `E_INSUFFICIENT_BALANCE` via `pay` if not enough ZAP
    public entry fun buy_merch(
        user: &signer, merch_type_id: u64, quantity: u64
    ) acquires MerchTable, Inventory, Events, Config, Treasury, UsersList, MerchCounters, UserMerchCap {
        let user_addr = signer::address_of(user);
        has_registered(user_addr);
        let now = ensure_in_window();
        assert!(quantity > 0, E_INVALID_ARGUMENT);
        assert!(quantity == 1, E_USER_DAILY_LIMIT); // cannot buy more than 1

        let mt = borrow_global_mut<MerchTable>(admin_addr()); // ensure merch table exists
        assert!(
            Table::contains(&mt.items, merch_type_id),
            E_MERCH_TYPE_DOESNT_EXIST
        );

        // --- PER-USER SEASON CAP (1 total of each type) ---
        let u_cap = borrow_global_mut<UserMerchCap>(user_addr);
        if (Table::contains(&u_cap.bought_merch, merch_type_id)) {
            assert!(
                !(*Table::borrow(&u_cap.bought_merch, merch_type_id)),
                E_USER_MERCH_CAP_CROSSED
            ); // already bought once
        };

        let cfg = borrow_global<Config>(admin_addr());
        let admin_addr = cfg.admin;

        // --- TIME WINDOWS ---
        let day_index = day_index(cfg.season_start_ts, now);
        let window_index = (now - cfg.season_start_ts) / 21600; // 6 hours = 21600s

        let m_cntrs = borrow_global_mut<MerchCounters>(admin_addr);

        // compute flattened composite keys
        let daily_key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + day_index;
        let window_key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + window_index;

        let total_sold_ref = get_or_init_u64(
            &mut m_cntrs.total_merch_sold, merch_type_id
        );
        let merch_type = Table::borrow_mut(&mut mt.items, merch_type_id);
        let window_limit = merch_type.total_supply / 4; // 25% of total supply per 6-hour window

        // --- STOCK VALIDATION TOTAL ---
        let new_sold = merch_type.sold + quantity;
        assert!(new_sold <= merch_type.total_supply, E_PURCHASE_SUPPLY_EXCEEDED);

        // // --- GLOBAL DAILY CAP (100 released per day && carry forward to next day if unsold ) ---
        // assert!(
        //     *total_sold_ref + quantity <= 100 * (day_index + 1),
        //     E_MERCH_DAILY_LIMIT_CROSSED
        // );
        let daily_sold_ref = get_or_init_u64(&mut m_cntrs.daily_merch_sold, daily_key);

        // --- GLOBAL 6-HOUR WINDOW CAP ((total_supply / 4) per window && carry forward to next window if unsold) ---
        assert!(
            *total_sold_ref + quantity <= window_limit * (window_index + 1),
            E_MERCH_HOUR_WINDOW_LIMIT_CROSSED
        );
        let window_sold_ref = get_or_init_u64(&mut m_cntrs.window_merch_sold, window_key);

        let total_price = merch_type.price * quantity;
        pay(user, total_price);
        merch_type.sold = new_sold;

        // update global counters
        *daily_sold_ref = *daily_sold_ref + quantity;
        *window_sold_ref = *window_sold_ref + quantity;
        *total_sold_ref = *total_sold_ref + quantity;

        // mark user cap used
        Table::upsert(&mut u_cap.bought_merch, merch_type_id, true);

        // record user inventory
        let inv = borrow_global_mut<Inventory>(user_addr);
        if (Table::contains(&inv.merch, merch_type_id)) {
            let q = Table::borrow_mut(&mut inv.merch, merch_type_id);
            q.quantity = q.quantity + quantity;
            q.purchase_time = now;
            // *q = *q + quantity;
        } else {
            let um = UserMerch {
                type_id: merch_type_id,
                quantity,
                price: merch_type.price,
                purchase_time: now
            };
            Table::add(&mut inv.merch, merch_type_id, um);
            vector::push_back(&mut inv.merch_type_ids, merch_type_id);
        };

        // emit event
        event::emit_event<MerchPurchased>(
            &mut borrow_global_mut<Events>(admin_addr).merch_purchased,
            MerchPurchased {
                user: user_addr,
                merch_type_id,
                quantity,
                paid_zap: total_price,
                timestamp: now
            }
        );
    }

    /********** OPEN CRATE **********/
    /// initiate open crate request (request randomness)
    /// store nonce for crate_id in NonceEntry after requesting randomness
    /// Initiates a crate opening by requesting VRF and recording the crate-specific nonce.
    ///
    /// Validates the crate is owned by the caller, is not already opened,
    /// and the unlock time has passed. Requests one random number and
    /// stores the resulting `nonce` in `NonceEntry.crate_nonce[crate_id]`.
    ///
    /// # Aborts with:
    /// - `E_UNLOCK_TOO_EARLY` if called before crate unlock time
    /// - `E_CRATE_ALREADY_OPENED` if crate already opened
    public entry fun open_crate(
        user: &signer, crate_id: u64
    ) acquires Inventory, UsersList, RandomNumberList, NonceEntry, PermitCap {
        let user_addr = signer::address_of(user);
        has_registered(user_addr);

        let inv = borrow_global_mut<Inventory>(user_addr);
        assert!(Table::contains(&inv.crates, crate_id), E_USER_DOESNT_OWN_THIS_CRATE);
        let crate_ref = Table::borrow(&inv.crates, crate_id);
        let now = timestamp::now_seconds();
        assert!(now >= crate_ref.unlock_ts, E_UNLOCK_TOO_EARLY);
        assert!(!crate_ref.opened, E_CRATE_ALREADY_OPENED);

        // --- REQUEST RANDOMNESS ---
        let callback_function = string::utf8(b"rng_response_crate");
        let nonce = rng_request_internal(user, 1, now, 1, callback_function);
        let nonce = *vector::borrow(&nonce, 0);
        let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
        Table::upsert(&mut nonce_entry.crate_nonce, nonce, crate_id);
    }

    // /// This function shall be called by user after some time (30s+) to allow VRF to process the request
    // /// finalize open crate request (get randomness and resolve prize)
    // /// check nonce for crate_id in NonceEntry, get randomness and resolve prize.abort
    // /// Finalizes crate opening by consuming VRF output and awarding the prize.
    // ///
    // /// Validates crate state and presence of a VRF `nonce`, fetches the random number(s),
    // /// computes a `rng_1_to_100` bucket, resolves a prize via `resolve_prize`,
    // /// and transfers Supra tokens from a resource signer account to the user.
    // ///
    // /// Then marks the crate as opened and stores the prize and timestamp.
    // /// Emits `CrateOpened`.
    // ///
    // /// # Aborts with:
    // /// - `E_UNLOCK_TOO_EARLY` if before unlock time
    // /// - `E_CRATE_ALREADY_OPENED` if already opened
    // /// - `E_NONCE_NOT_GENERATED_FOR_CRATE` if `open_crate` wasnt called or VRF not ready
    // public entry fun open_crate_finalize(
    //     user: &signer, crate_id: u64
    // ) acquires Config, Inventory, Events, UsersList, NonceEntry, RandomNumberList, ResourceSignerCap {
    //     let user_addr = signer::address_of(user);
    //     has_registered(user_addr);

    //     let cfg = borrow_global<Config>(admin_addr());
    //     let inv = borrow_global_mut<Inventory>(user_addr);

    //     assert!(Table::contains(&inv.crates, crate_id), E_USER_DOESNT_OWN_THIS_CRATE);
    //     let crate_ref = Table::borrow_mut(&mut inv.crates, crate_id);
    //     let now = timestamp::now_seconds();
    //     assert!(now >= crate_ref.unlock_ts, E_UNLOCK_TOO_EARLY);
    //     assert!(!crate_ref.opened, E_CRATE_ALREADY_OPENED);
    //     let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
    //     assert!(
    //         Table::contains(&nonce_entry.crate_nonce, crate_id),
    //         E_NONCE_NOT_GENERATED_FOR_CRATE
    //     );
    //     let nonce = Table::borrow(&mut nonce_entry.crate_nonce, crate_id);
    //     let rand_nums = get_rng_numbers_from_nonce(*nonce);
    //     let rng_u256 = *vector::borrow(&rand_nums, 0);
    //     let rng_1_to_100 = ((rng_u256 % 100) as u8) + 1;

    //     assert!(
    //         rng_1_to_100 >= 1 && rng_1_to_100 <= 100,
    //         E_INVALID_ARGUMENT
    //     );

    //     let prize =
    //         resolve_prize(
    //             crate_ref.tier, rng_1_to_100, cfg.crate_max_single_prize_supra
    //         );

    //     let resource_signer_cap = borrow_global<ResourceSignerCap>(@ZAPSHOP);
    //     // let resource_signer =
    //     //     account::create_signer_with_capability(&resource_signer_cap.signer_cap);
    //     // supra_account::transfer(&resource_signer, user_addr, prize * SUPRA_DECIMALS);

    //     crate_ref.opened = true;
    //     crate_ref.prize = option::some<u64>(prize);
    //     crate_ref.opened_ts = option::some<u64>(now);

    //     event::emit_event<CrateOpened>(
    //         &mut borrow_global_mut<Events>(cfg.admin).crate_opened,
    //         CrateOpened {
    //             user: user_addr,
    //             crate_id,
    //             tier: crate_ref.tier,
    //             prize_supra_alloted: prize,
    //             timestamp: now
    //         }
    //     );
    // }

    public entry fun claim_crate_prize(
        user: &signer, crate_id: u64
    ) acquires Inventory, UsersList, Events, ResourceSignerCap, Config {
        let user_addr = signer::address_of(user);
        has_registered(user_addr);

        let inv = borrow_global_mut<Inventory>(user_addr);
        assert!(Table::contains(&inv.crates, crate_id), E_USER_DOESNT_OWN_THIS_CRATE);
        let crate_ref = Table::borrow_mut(&mut inv.crates, crate_id);
        assert!(crate_ref.opened, E_CRATE_NOT_YET_OPENED);
        assert!(!crate_ref.is_prize_claimed, E_CRATE_PRIZE_ALREADY_CLAIMED);
        let prize = option::borrow<u64>(&mut crate_ref.prize);
        let resource_signer_cap = borrow_global<ResourceSignerCap>(@ZAPSHOP);
        let resource_signer =
            account::create_signer_with_capability(&resource_signer_cap.signer_cap);
        supra_account::transfer(&resource_signer, user_addr, *prize * SUPRA_DECIMALS);
        crate_ref.is_prize_claimed = true;

        let cfg = borrow_global<Config>(admin_addr());
        let now = timestamp::now_seconds();
        event::emit_event<CratePrizeClaimed>(
            &mut borrow_global_mut<Events>(cfg.admin).crate_prize_claimed,
            CratePrizeClaimed {
                user: user_addr,
                crate_id,
                prize_supra_claimed: *prize,
                timestamp: now
            }
        );
    }

    /********** PICK RAFFLE WINNER **********/
    /// Starts the process of selecting raffle winners by requesting VRF.
    ///
    /// Requests `number_of_winners * 2` random numbers (added entropy / retries),
    /// stores the resulting nonce vector in `NonceEntry.raffle_nonce`.
    ///
    /// # Parameters
    /// - `number_of_winners`: target number of distinct winners to pick
    /// - `type_id`: raffle type to draw (used later in finalize)
    ///
    /// # Access
    /// Admin only.
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin caller
    public entry fun pick_raffle_winners_init(
        admin: &signer, number_of_winners: u64, type_id: u8
    ) acquires Config, RandomNumberList, NonceEntry, PermitCap {
        let cfg = borrow_global<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);
        let callback_function = string::utf8(b"rng_response_raffle");

        let nonce =
            rng_request_internal(
                admin,
                number_of_winners * 2,
                timestamp::now_seconds(),
                1,
                callback_function
            );
        let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
        nonce_entry.raffle_nonce = option::some<vector<u64>>(nonce);
    }

    /// Finalizes the raffle winner selection using VRF results.
    ///
    /// Reads nonces from `NonceEntry`, fetches all random numbers, maps each to an index
    /// within the sold raffle IDs, and picks distinct winners per tier (no duplicate winner
    /// within the same tier). Accumulates winners until `number_of_winners` is reached.
    ///
    /// Emits `RaffleWinnerPicked` containing the winner addresses and their raffle IDs.
    /// If `is_prize_supra` is true, the caller is expected to distribute Supra coins off-chain
    /// or by a later on-chain routine (transfer is commented out here).
    ///
    /// # Parameters
    /// - `number_of_winners`: number of winners to choose
    /// - `type_id`: raffle type being drawn (tier computed as `type_id / 10`)
    /// - `is_prize_supra`: whether the prize is Supra tokens (vs physical prize)
    /// - `prize_supra`: prize amount per winner in Supra base units (no decimals applied here)
    ///
    /// # Access
    /// Admin only.
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin
    /// - `E_NONCE_NOT_GENERATED_FOR_RAFFLE` if `pick_raffle_winners_init` was not called or not completed
    public entry fun pick_raffle_winners_finalize(
        admin: &signer, number_of_winners: u64, type_id: u8
    ) acquires Config, RandomNumberList, RafflesList, RaffleWinners, NonceEntry, Events {
        let cfg = borrow_global<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);

        let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
        assert!(
            option::is_some(&nonce_entry.raffle_nonce),
            E_NONCE_NOT_GENERATED_FOR_RAFFLE
        );
        let nonces: vector<u64> =
            option::extract<vector<u64>>(&mut nonce_entry.raffle_nonce);

        let r_w = borrow_global_mut<RaffleWinners>(admin_addr()); // ensure resource exists
        let r_l = borrow_global_mut<RafflesList>(admin_addr());
        let r_l_raffle_ids_by_type = Table::borrow(&r_l.raffle_ids_by_type, type_id);
        let total_raffles_in_type = vector::length(r_l_raffle_ids_by_type);

        let i = 0;
        let all_rand_nums = vector::empty<u256>();
        while (i < vector::length(&nonces)) {
            let nonce = *vector::borrow(&nonces, i);
            let rns = get_rng_numbers_from_nonce(nonce);
            vector::append(&mut all_rand_nums, rns);
            i = i + 1;
        };

        let r_w_tmp = vector::empty<address>();
        let r_ids_tmp = vector::empty<u64>();
        let len = vector::length(&all_rand_nums);
        let tier = type_id / 10;
        if (!Table::contains(&r_w.winners_by_tier, tier)) {
            Table::add(&mut r_w.winners_by_tier, tier, vector::empty<address>());
        };
        if (!Table::contains(&r_w.winners_by_type_id, type_id)) {
            Table::add(&mut r_w.winners_by_type_id, type_id, vector::empty<address>());
        };

        let w_by_tier = Table::borrow_mut(&mut r_w.winners_by_tier, tier);
        let w_by_type_id = Table::borrow_mut(&mut r_w.winners_by_type_id, type_id);

        let i = 0;
        while (i < len) {
            let rn = *vector::borrow(&all_rand_nums, i);
            let rnd_u64 =
                if (rn < (total_raffles_in_type as u256)) {
                    (rn as u64)
                } else {
                    ((rn % (total_raffles_in_type as u256)) as u64)
                };
            let picked_raffle_id = *vector::borrow(r_l_raffle_ids_by_type, rnd_u64);
            let picked_user = *Table::borrow(&r_l.raffle_id_user, picked_raffle_id);

            // If the picked address is already a winner in this tier already, skip and continue to pick other users
            if (vector::contains(w_by_tier, &picked_user)) {
                i = i + 1;
                continue
            } else {
                // new winner
                vector::push_back(w_by_tier, picked_user);
                vector::push_back(w_by_type_id, picked_user);
                vector::push_back(&mut r_w.raffle_ids, picked_raffle_id);
                vector::push_back(&mut r_ids_tmp, picked_raffle_id);
                vector::push_back(&mut r_w_tmp, picked_user);
                if (vector::length(&r_w_tmp) >= (number_of_winners as u64)) { break };
                i = i + 1;
            }
        };

        event::emit_event<RaffleWinnerPicked>(
            &mut borrow_global_mut<Events>(cfg.admin).raffle_winner_picked,
            RaffleWinnerPicked {
                raffle_ids: r_ids_tmp,
                winners: r_w_tmp,
                type_id,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /********** VRF RANDOMNESS GENERATION LOGIC **********/
    /// Make request
    /// Internal helper to request VRF random numbers from Supra.
    ///
    /// Makes one or two requests depending on `rng_count` (splits if >255),
    /// and stores an empty vector placeholder at `RandomNumberList.list[nonce]`
    /// for each request. Returns the vector of nonces to poll later.
    ///
    /// # Parameters
    /// - `rng_count`: number of random numbers requested per call (max 255; splits if larger)
    /// - `client_seed`: arbitrary client-provided seed to mix into VRF
    /// - `num_confirmations`: confirmation parameter for VRF (e.g., 1)
    ///
    /// # Returns
    /// A vector of nonces, each corresponding to a VRF request.
    ///
    /// # Access
    /// Only callable by functions that own or rely on the `PermitCap`.
    ///
    /// # Notes
    /// The callback function is fixed as `"rng_response"`.
    fun rng_request_internal(
        _sender: &signer,
        rng_count: u64,
        client_seed: u64,
        num_confirmations: u64,
        callback_function: String
    ): vector<u64> acquires RandomNumberList, PermitCap {
        let multiple_call = 1;
        if (rng_count > 255) {
            rng_count = (rng_count / 4);
            multiple_call = 4;
        };
        let nonce_list = vector::empty<u64>();
        let cap = borrow_global<PermitCap>(@ZAPSHOP);
        while (multiple_call > 0) {
            let nonce =
                supra_vrf::rng_request_v2(
                    &cap.permit,
                    callback_function,
                    (rng_count as u8),
                    client_seed,
                    num_confirmations
                );

            let tbl = &mut borrow_global_mut<RandomNumberList>(@ZAPSHOP).list;
            Table::upsert(tbl, nonce, vector::empty<u256>());
            multiple_call = multiple_call - 1;
            vector::push_back(&mut nonce_list, nonce);
        };
        nonce_list
    }

    /// Handle callback
    /// VRF callback entry point stores verified random numbers by nonce.
    ///
    /// Verifies the message/signature via `supra_vrf::verify_callback`
    /// and writes the resulting vector<u256> into `RandomNumberList.list[nonce]`.
    ///
    /// # Parameters
    /// - `nonce`: VRF-request handle
    /// - `message`, `signature`, `caller_address`: VRF proof packet
    /// - `rng_count`, `client_seed`: original request parameters (for verification)
    ///
    /// # Effects
    /// - Mutates `RandomNumberList` at key `nonce` to hold the VRF output.
    ///
    /// # Aborts with:
    /// - Any aborts raised by `verify_callback` on invalid proofs.
    public entry fun rng_response_crate(
        nonce: u64,
        message: vector<u8>,
        signature: vector<u8>,
        caller_address: address,
        rng_count: u8,
        client_seed: u64
    ) acquires Events, NonceEntry, Inventory, Config, CrateTable {
        let random_numbers: vector<u256> =
            supra_vrf::verify_callback(
                nonce,
                message,
                signature,
                caller_address,
                rng_count,
                client_seed
            );
        let cfg = borrow_global<Config>(admin_addr());

        let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
        assert!(
            Table::contains(&nonce_entry.crate_nonce, nonce),
            E_NONCE_NOT_ASSIGNED_FOR_CRATE
        );
        let crate_id = *Table::borrow(&nonce_entry.crate_nonce, nonce);
        let crate_table = borrow_global_mut<CrateTable>(admin_addr());
        let user_addr = Table::borrow(&crate_table.crate_owner, crate_id);
        let inv = borrow_global_mut<Inventory>(*user_addr);
        let crate_ref = Table::borrow_mut(&mut inv.crates, crate_id);
        let rng_u256 = *vector::borrow(&random_numbers, 0);
        let rng_1_to_100 = ((rng_u256 % 100) as u8) + 1;
        let prize =
            resolve_prize(
                crate_ref.tier, rng_1_to_100, cfg.crate_max_single_prize_supra
            );

        let now = timestamp::now_seconds();
        crate_ref.opened = true;
        crate_ref.prize = option::some<u64>(prize);
        crate_ref.opened_ts = option::some<u64>(now);

        event::emit_event<CrateOpened>(
            &mut borrow_global_mut<Events>(cfg.admin).crate_opened,
            CrateOpened {
                user: crate_ref.owner,
                crate_id,
                tier: crate_ref.tier,
                prize_supra_alloted: prize,
                timestamp: now,
                month_slot: crate_ref.month_slot
            }
        );
    }

    public entry fun rng_response_raffle(
        nonce: u64,
        message: vector<u8>,
        signature: vector<u8>,
        caller_address: address,
        rng_count: u8,
        client_seed: u64
    ) acquires RandomNumberList {
        let random_numbers: vector<u256> =
            supra_vrf::verify_callback(
                nonce,
                message,
                signature,
                caller_address,
                rng_count,
                client_seed
            );
        let tbl = &mut borrow_global_mut<RandomNumberList>(@ZAPSHOP).list;
        let entry = Table::borrow_mut(tbl, nonce);
        *entry = random_numbers;
    }

    /// ********** ADMIN CONFIG MODIFIERS **********/
    /// Modifies the total supply and price of an existing merchandise type.
    ///
    /// # Parameters
    /// - `merch_type_id`: unique ID for this merchandise type.
    /// - `new_total_supply`: new total supply to set.
    /// - `new_price`: new price to set in ZAP base units.
    /// # Access
    /// Admin only.
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin calls it.
    /// - `E_MERCH_TYPE_DOESNT_EXIST` if the merch type ID is not found.
    public entry fun modify_merch_total_supply_price(
        admin: &signer,
        merch_type_id: u64,
        new_total_supply: u64,
        new_price: u64
    ) acquires MerchTable, Config {
        let cfg = borrow_global<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);

        let mt = borrow_global_mut<MerchTable>(cfg.admin);
        assert!(Table::contains(&mt.items, merch_type_id), E_MERCH_TYPE_DOESNT_EXIST);
        let m = Table::borrow_mut(&mut mt.items, merch_type_id);
        m.total_supply = new_total_supply;
        m.price = new_price;
    }

    /// Modify crate totals and per-day limits
    /// Admin-only entry to modify crate totals and per-day limits.
    /// # Parameters
    /// - `bronze_total`, `silver_total`, `gold_total`: new total supplys
    /// - `bronze_per_day`, `silver_per_day`, `gold_per_day`: new per-day limits
    /// # Access
    /// Admin only.
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin caller
    public entry fun modify_crate_totals(
        admin: &signer,
        bronze_total: u64,
        silver_total: u64,
        gold_total: u64,
        bronze_per_day: u64,
        silver_per_day: u64,
        gold_per_day: u64
    ) acquires Config {
        ensure_admin(admin);
        let cfg = borrow_global_mut<Config>(admin_addr());
        cfg.bronze_total = bronze_total;
        cfg.silver_total = silver_total;
        cfg.gold_total = gold_total;
        cfg.bronze_per_day = bronze_per_day;
        cfg.silver_per_day = silver_per_day;
        cfg.gold_per_day = gold_per_day;
    }

    /// Modify crate prices
    /// Admin-only entry to modify crate prices.
    /// # Parameters
    /// - Prices for bronze, silver, gold crates for month slots M1, M2, M3
    /// # Access
    /// Admin only.
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin caller
    public entry fun modify_crate_prices(
        admin: &signer,
        price_bronze_crate_m1: u64,
        price_bronze_crate_m2: u64,
        price_bronze_crate_m3: u64,
        price_silver_crate_m1: u64,
        price_silver_crate_m2: u64,
        price_silver_crate_m3: u64,
        price_gold_crate_m1: u64,
        price_gold_crate_m2: u64,
        price_gold_crate_m3: u64
    ) acquires Config {
        ensure_admin(admin);
        let cfg = borrow_global_mut<Config>(admin_addr());
        cfg.price_bronze_crate_m1 = price_bronze_crate_m1;
        cfg.price_bronze_crate_m2 = price_bronze_crate_m2;
        cfg.price_bronze_crate_m3 = price_bronze_crate_m3;
        cfg.price_silver_crate_m1 = price_silver_crate_m1;
        cfg.price_silver_crate_m2 = price_silver_crate_m2;
        cfg.price_silver_crate_m3 = price_silver_crate_m3;
        cfg.price_gold_crate_m1 = price_gold_crate_m1;
        cfg.price_gold_crate_m2 = price_gold_crate_m2;
        cfg.price_gold_crate_m3 = price_gold_crate_m3;
    }

    /// Modify raffle prices
    /// Admin-only entry to modify raffle prices.
    /// # Parameters
    /// - Prices for raffle types A, B, C, D
    /// # Access
    /// Admin only.
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin caller
    public entry fun modify_raffle_price(
        admin: &signer,
        raffle_price_a: u64,
        raffle_price_b: u64,
        raffle_price_c: u64,
        raffle_price_d: u64
    ) acquires Config {
        ensure_admin(admin);
        let cfg = borrow_global_mut<Config>(admin_addr());
        cfg.raffle_price_A = raffle_price_a;
        cfg.raffle_price_B = raffle_price_b;
        cfg.raffle_price_C = raffle_price_c;
        cfg.raffle_price_D = raffle_price_d;
    }

    #[view]
    /// Get generated random number
    /// View: Returns the VRF-generated random numbers for a given `nonce`.
    ///
    /// # Returns
    /// The vector<u256> previously stored by `rng_response`.
    public fun get_rng_numbers_from_nonce(nonce: u64): vector<u256> acquires RandomNumberList {
        let tbl = borrow_global<RandomNumberList>(@ZAPSHOP);
        assert!(
            Table::contains(&tbl.list, nonce),
            E_NONCE_NOT_ASSIGNED_FOR_CRATE
        );
        let random_numbers = Table::borrow(&tbl.list, nonce);
        *random_numbers
    }

    fun generate_random_number(lower_bound: u8, upper_bound: u8): u8 {
        let random_number = randomness::u8_range(lower_bound, upper_bound);
        random_number
    }

    /********** HELPERS **********/
    fun ensure_admin(s: &signer) acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        assert!(signer::address_of(s) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);
    }

    /// Helper: Charges ZAP from the user and deposits into the Treasury.
    ///
    /// Asserts the user has at least `amt`, withdraws that amount of ZAP,
    /// and deposits to the admin treasury address.
    ///
    /// # Aborts with:
    /// - `E_INSUFFICIENT_BALANCE` if users ZAP balance < `amt`.
    fun pay(user: &signer, amt: u64) acquires Treasury {
        let treasury = borrow_global<Treasury>(admin_addr()).addr;
        assert!(
            amt <= coin::balance<ZAP>(signer::address_of(user)),
            E_INSUFFICIENT_BALANCE
        );
        let coins = coin::withdraw<ZAP>(user, amt);
        coin::deposit<ZAP>(treasury, coins);
    }

    /// Helper: Ensures the current timestamp is within season window.
    ///
    /// Asserts now  [`season_start_ts`, `season_end_ts`], and returns `now`.
    ///
    /// # Aborts with:
    /// - `E_OUT_OF_SALE_WINDOW_PERIOD` if outside the allowed window.
    fun ensure_in_window(): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        let now = timestamp::now_seconds();
        assert!(
            now >= cfg.season_start_ts && now <= cfg.season_end_ts,
            E_OUT_OF_SALE_WINDOW_PERIOD
        );
        now
    }

    fun day_index(start: u64, now: u64): u64 {
        (now - start) / SECS_PER_DAY
    }

    /// Get or initialize a u64 in a table keyed by day.
    /// Helper: Returns a mutable reference to a `u64` at `day`, inserting 0 if missing.
    ///
    /// Useful for daily counters that must always exist before incrementing.
    fun get_or_init_u64(tbl: &mut Table<u64, u64>, day: u64): &mut u64 {
        if (!Table::contains(tbl, day)) {
            Table::add(tbl, day, 0);
        };
        Table::borrow_mut(tbl, day)
    }

    /// Get or initialize a DailyUser in a table keyed by day...
    /// Helper: Returns a mutable reference to `DailyUser` at `day`, inserting zeros if missing.
    ///
    /// Ensures daily per-user counters (`raffles`, `bronze`, `silver`, `gold`) are present.
    fun get_or_init_user(tbl: &mut Table<u64, DailyUser>, day: u64): &mut DailyUser {
        if (!Table::contains(tbl, day)) {
            let du = DailyUser { raffles: 0, bronze: 0, silver: 0, gold: 0 };
            Table::add(tbl, day, du);
        };
        Table::borrow_mut(tbl, day)
    }

    /// Resolves the Supra prize for a crate based on tier and RNG bucket.
    ///
    /// Scales `rng` (1..100) to finer granularity (1..10,000) and uses
    /// piecewise probability distributions per tier to choose a prize,
    /// then caps to `max_cap` if necessary.
    ///
    /// # Parameters
    /// - `tier`: one of `TIER_BRONZE`, `TIER_SILVER`, `TIER_GOLD`
    /// - `rng`: integer in 1..=100 (bucket)
    /// - `max_cap`: maximum allowed prize (safety cap)
    ///
    /// # Returns
    /// The chosen prize amount in Supra (no decimals applied).
    public fun resolve_prize(tier: u8, rng: u8, max_cap: u64): u64 {
        let adjusted_rng: u64 = (rng as u64) * 10000u64; // scale to 1-10000 for finer granularity
        let p: u64;
        if (tier == TIER_BRONZE) {
            p =
                if (adjusted_rng <= 500000u64) 20
                // 50.00% probability
                else if (adjusted_rng <= 900000u64) 300
                // 40.00% probability
                else if (adjusted_rng <= 999900u64) 1600
                // 9.99% probability
                else 32000; // 0.01% probability

        } else if (tier == TIER_SILVER) {
            p =
                if (adjusted_rng <= 500000u64) 80
                // 50.00% probability
                else if (adjusted_rng <= 840000u64) 1600
                // 34.00% probability
                else if (adjusted_rng <= 990000u64) 8000
                // 15.00% probability
                else 32000;
            // 1% probability
        } else {
            p =
                if (adjusted_rng <= 440000u64) 320
                // 44% probability
                else if (adjusted_rng <= 780000u64) 1600
                // 34% probability
                else if (adjusted_rng <= 930000u64) 8000
                // 15% probability
                else 80000; // 7% probability
        };
        if (p > max_cap) {
            max_cap
        } else { p }
    }

    fun admin_addr(): address {
        @ZAPSHOP
    }

    /// Allows admin to withdraw Supra tokens from the resource signer account.
    ///
    public entry fun withdraw_supra_from_resource_signer(
        admin: &signer, to: address, amount: u64
    ) acquires ResourceSignerCap, Config {
        ensure_admin(admin);
        let resource_signer_cap = borrow_global<ResourceSignerCap>(@ZAPSHOP);
        let resource_signer =
            account::create_signer_with_capability(&resource_signer_cap.signer_cap);
        supra_account::transfer(&resource_signer, to, amount);
    }

    /// Test-only bootstrap function for local or unit tests.
    ///
    /// Invokes `init_module()` internally to set up all global resources.
    /// Used during test scenarios to simulate full contract deployment.
    ///
    /// # Access
    /// Test-only; should not be used in production.
    #[test_only]
    public entry fun test_bootstrap(admin: &signer) {
        init_module(admin);
    }

    /// Allows admin to change the overall season start and end timestamps.
    ///
    /// Updates the time window during which sales are permitted for
    /// raffles, crates, and merchandise.
    ///
    /// # Parameters
    /// - `new_start_ts`: new season start timestamp.
    /// - `new_end_ts`: new season end timestamp.
    ///
    /// # Access
    /// Admin only.
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin attempts to call.
    public entry fun change_configs(
        admin: &signer, new_start_ts: u64, new_end_ts: u64
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);
        cfg.season_start_ts = new_start_ts;
        cfg.season_end_ts = new_end_ts;
    }

    /// Allows admin to modify crate opening time slots (M1, M2, M3).
    ///
    /// Each crate tier has predefined unlock times; this function
    /// lets admin adjust those in case of schedule changes.
    ///
    /// # Parameters
    /// - `new_m1`, `new_m2`, `new_m3`: updated unlock timestamps.
    ///
    /// # Access
    /// Admin only.
    ///
    /// # Aborts with:
    /// - `E_ONLY_ADMIN_PRIVILEDGE` if non-admin attempts to call.
    public entry fun change_crate_opening_timeslots(
        admin: &signer,
        new_m1: u64,
        new_m2: u64,
        new_m3: u64
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr());
        assert!(signer::address_of(admin) == cfg.admin, E_ONLY_ADMIN_PRIVILEDGE);
        cfg.crate_open_start_m1 = new_m1;
        cfg.crate_open_start_m2 = new_m2;
        cfg.crate_open_start_m3 = new_m3;
    }

    #[test_only]
    public entry fun simulate_randomness_raffles(
        admin: &signer,
        len: u64,
        nonce_vec: vector<u64>,
        lower_bound: u256,
        upper_bound: u256
    ) acquires RandomNumberList, NonceEntry {
        assert!(signer::address_of(admin) == admin_addr(), E_ONLY_ADMIN_PRIVILEDGE);
        let nonce_entry = borrow_global_mut<NonceEntry>(admin_addr());
        nonce_entry.raffle_nonce = option::some<vector<u64>>(nonce_vec);

        let nonce_length = vector::length(&nonce_vec);
        while (nonce_length > 0) {
            let rn_vec = vector::empty<u256>();

            while (len > 0) {
                let rn = randomness::u256_range(lower_bound, upper_bound);
                vector::push_back(&mut rn_vec, rn);
                len = len - 1;
            };

            let tbl = &mut borrow_global_mut<RandomNumberList>(@ZAPSHOP).list;
            let nx = *vector::borrow(&nonce_vec, nonce_length - 1);
            Table::upsert(tbl, nx, vector::empty<u256>());
            let entry = Table::borrow_mut(tbl, nx);
            *entry = rn_vec;
            nonce_length = nonce_length - 1;
        };
    }

    #[view]
    public fun get_config_copy(): Config acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        let new_config = Config {
            admin: cfg.admin,
            season_start_ts: cfg.season_start_ts,
            season_end_ts: cfg.season_end_ts,
            crate_open_start_m1: cfg.crate_open_start_m1,
            crate_open_start_m2: cfg.crate_open_start_m2,
            crate_open_start_m3: cfg.crate_open_start_m3,
            bronze_total: cfg.bronze_total,
            silver_total: cfg.silver_total,
            gold_total: cfg.gold_total,
            bronze_per_day: cfg.bronze_per_day,
            silver_per_day: cfg.silver_per_day,
            gold_per_day: cfg.gold_per_day,
            bronze_user_cap_per_day: cfg.bronze_user_cap_per_day,
            silver_user_cap_per_day: cfg.silver_user_cap_per_day,
            gold_user_cap_per_day: cfg.gold_user_cap_per_day,
            raffle_price_A: cfg.raffle_price_A,
            raffle_price_B: cfg.raffle_price_B,
            raffle_price_C: cfg.raffle_price_C,
            raffle_price_D: cfg.raffle_price_D,
            // purchase prices chosen by (tier, month_slot)
            price_bronze_crate_m1: cfg.price_bronze_crate_m1,
            price_bronze_crate_m2: cfg.price_bronze_crate_m2,
            price_bronze_crate_m3: cfg.price_bronze_crate_m3,
            price_silver_crate_m1: cfg.price_silver_crate_m1,
            price_silver_crate_m2: cfg.price_silver_crate_m2,
            price_silver_crate_m3: cfg.price_silver_crate_m3,
            price_gold_crate_m1: cfg.price_gold_crate_m1,
            price_gold_crate_m2: cfg.price_gold_crate_m2,
            price_gold_crate_m3: cfg.price_gold_crate_m3,
            crate_max_single_prize_supra: cfg.crate_max_single_prize_supra,
            zap_decimals: cfg.zap_decimals
        };
        new_config
    }

    /// Test-only view: returns the full registered users list.
    #[view]
    public fun get_users_list(): vector<address> acquires UsersList {
        let ul = borrow_global<UsersList>(admin_addr());
        ul.users
    }

    #[view]
    public fun check_user_initiated(user: address): (bool, u64) acquires UsersList {
        let ul = borrow_global<UsersList>(admin_addr());
        let res = Table::contains(&ul.users_init_balance, user);
        if (res) {
            (true, *Table::borrow(&ul.users_init_balance, user))
        } else {
            (false, 0)
        }
    }

    /// Test-only view: returns (admin address, ZAP decimals) from Config.
    #[test_only]
    public entry fun get_config_admin_decimals(): (address, u8) acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        (cfg.admin, cfg.zap_decimals)
    }

    // ********* VIEWS FOR RAFFLES ********** //
    /// View: returns all raffle IDs owned by `user`.
    #[view]
    public fun get_user_raffles(user: address): vector<u64> acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        inv.raffle_ids
    }

    /// View: returns all raffle IDs of a given type owned by `user`.
    #[view]
    public fun get_user_raffles_by_type_id(user: address, type_id: u8): vector<u64> acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let rafs = inv.raffle_ids;
        let result = vector::empty<u64>();
        let len = vector::length(&rafs);
        while (len > 0) {
            let r = *vector::borrow(&rafs, len - 1);
            if ((r / 100000000000000) == (type_id as u64)) {
                vector::push_back(&mut result, r);
            };
            len = len - 1;
        };
        result
    }

    /// View: returns all raffle IDs ever sold.
    #[view]
    public fun get_all_raffles_sold(): vector<u64> acquires RafflesList {
        let rl = borrow_global<RafflesList>(admin_addr());
        rl.raffle_ids
    }

    /// View: returns the owner address for a given `raffle_id`.
    #[view]
    public fun get_raffle_owner(raffle_id: u64): address acquires RafflesList {
        let rl = borrow_global<RafflesList>(admin_addr());
        *Table::borrow(&rl.raffle_id_user, raffle_id)
    }

    /// View: returns winners for a given raffle `type_id`.
    ///
    /// Lazily initializes the winners-by-type entry to an empty vector if missing.
    #[view]
    public fun get_raffle_winners_by_type_id(type_id: u8): vector<address> acquires RaffleWinners {
        let rw = borrow_global<RaffleWinners>(admin_addr());
        if (!Table::contains(&rw.winners_by_type_id, type_id)) {
            return vector::empty<address>()
        };
        *Table::borrow(&rw.winners_by_type_id, type_id)
    }

    // ********* VIEWS FOR CRATES ********** //
    /// View: checks if a specific user crate has been opened.
    #[view]
    public fun check_crate_opened(user: address, crate_id: u64): bool acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let crate_ref = Table::borrow(&inv.crates, crate_id);
        crate_ref.opened
    }

    /// View: returns the `opened_ts` (Option<u64>) for a given user crate.
    #[view]
    public fun get_user_crate_opened_timestamp(
        user: address, crate_id: u64
    ): option::Option<u64> acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let crate_ref = Table::borrow(&inv.crates, crate_id);
        crate_ref.opened_ts
    }

    /// View: returns all crate IDs owned by `user`.
    #[view]
    public fun get_user_crate_ids(user: address): vector<u64> acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let ids = inv.crate_ids;
        ids
    }

    /// View: returns the full `Crate` struct for a given user and crate ID.
    /// Includes tier, unlock time, opened status, prize, and opened timestamp.
    ///
    #[view]
    public fun get_user_crate_details(user: address, crate_id: u64): Crate acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let crate_ref = Table::borrow(&inv.crates, crate_id);
        *crate_ref
    }

    #[view]
    public fun get_prize_alloted(user: address, crate_id: u64): u64 acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        let crate_ref = Table::borrow(&inv.crates, crate_id);
        *option::borrow<u64>(&crate_ref.prize)
    }

    /// View: returns the next daily sale timestamp for crates.
    ///
    /// If before season, returns `season_start_ts`.
    /// If after season, returns `0`.
    /// Otherwise, returns the start of the next day boundary from current time.
    #[view]
    public fun get_next_crate_sale_timestamp(): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        if (timestamp::now_seconds() < cfg.season_start_ts) {
            cfg.season_start_ts
        } else if (timestamp::now_seconds() > cfg.season_end_ts) { 0 }
        else {
            let day_index = (timestamp::now_seconds() - cfg.season_start_ts)
                / SECS_PER_DAY;
            cfg.season_start_ts + (day_index + 1) * SECS_PER_DAY
        }
    }

    /// View: returns all three crate unlock timestamps (M1, M2, M3).
    #[view]
    public fun get_crate_unlock_timestamps(): (u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        (cfg.crate_open_start_m1, cfg.crate_open_start_m2, cfg.crate_open_start_m3)
    }

    /// View: returns cumulative total crates sold per tier (gold, silver, bronze).
    #[view]
    public fun get_bronze_silver_gold_crate_total_sold(): (u64, u64, u64) acquires GlobalTotals {
        let gt = borrow_global<GlobalTotals>(admin_addr());
        (gt.bronze_sold_total, gt.silver_sold_total, gt.gold_sold_total)
    }

    /// View: returns cumulative total crates sold and total supply per tier.
    ///
    /// (u64, u64, u64) = (bronze_sold, bronze_total, silver_sold, silver_total, gold_sold, gold_total)
    #[view]
    public fun get_bronze_silver_gold_crate_total_supply_sold():
        (u64, u64, u64, u64, u64, u64) acquires GlobalTotals, Config {
        let gt = borrow_global<GlobalTotals>(admin_addr());
        let cfg = borrow_global<Config>(admin_addr());

        (
            cfg.bronze_total,
            gt.bronze_sold_total,
            cfg.silver_total,
            gt.silver_sold_total,
            cfg.gold_total,
            gt.gold_sold_total
        )
    }

    /// View: returns per-day crates sold per tier at `day_index`.
    ///
    /// (u64, u64, u64) = (gold_sold, silver_sold, bronze_sold)
    ///
    /// If a day entry is absent, returns 0 for that tier.
    #[view]
    public fun get_bronze_silver_gold_crate_daily_sold(
        day_index: u64
    ): (u64, u64, u64) acquires GlobalDayCounters {
        let gdc = borrow_global<GlobalDayCounters>(admin_addr());
        let gold_sold =
            if (Table::contains(&gdc.gold_sold, day_index)) {
                *Table::borrow(&gdc.gold_sold, day_index)
            } else { 0 };
        let silver_sold =
            if (Table::contains(&gdc.silver_sold, day_index)) {
                *Table::borrow(&gdc.silver_sold, day_index)
            } else { 0 };
        let bronze_sold =
            if (Table::contains(&gdc.bronze_sold, day_index)) {
                *Table::borrow(&gdc.bronze_sold, day_index)
            } else { 0 };
        (bronze_sold, silver_sold, gold_sold)
    }

    #[view]
    public fun get_user_crate_limit_daily(
        user: address, timestamp: u64
    ): DailyUser acquires UserDayCounters, Config {
        let cfg = borrow_global<Config>(admin_addr());
        let day_index = day_index(cfg.season_start_ts, timestamp);

        let userc = borrow_global<UserDayCounters>(user);
        if (Table::contains(&userc.per_day, day_index)) {
            *Table::borrow(&userc.per_day, day_index)
        } else {
            DailyUser { raffles: 0, bronze: 0, silver: 0, gold: 0 }
        }
    }

    // ********* VIEWS FOR MERCH ********** //
    /// View: returns quantity of a specific merch type owned by `user`.
    #[view]
    public fun get_user_merch_details(user: address, merch_type_id: u64): UserMerch acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        if (!Table::contains(&inv.merch, merch_type_id)) {
            return UserMerch {
                type_id: merch_type_id,
                quantity: 0,
                price: 0,
                purchase_time: 0
            }
        };
        *Table::borrow(&inv.merch, merch_type_id)
    }

    /// View: returns total merchandise sold across all types and time.
    #[view]
    public fun get_merch_counter_total_supply_sold(
        merch_type_id: u64
    ): (u64, Merch) acquires MerchCounters, MerchTable {
        let mc = borrow_global<MerchCounters>(admin_addr());
        let mtl = borrow_global<MerchTable>(admin_addr());
        let merch_type = Table::borrow(&mtl.items, merch_type_id);
        let total_sold = *Table::borrow(&mc.total_merch_sold, merch_type_id);
        (total_sold, *merch_type)
    }

    /// View: returns merchandise sold for a given type on a particular day index.
    ///
    /// If the daily entry is absent, returns 0.
    #[view]
    public fun get_merch_sold_daily(merch_type_id: u64, day_index: u64): u64 acquires MerchCounters {
        let mc = borrow_global<MerchCounters>(admin_addr());
        let daily_key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + day_index;
        if (Table::contains(&mc.daily_merch_sold, daily_key)) {
            *Table::borrow(&mc.daily_merch_sold, daily_key)
        } else { 0 }
    }

    /// View: returns merchandise sold for a given type within a particular 6-hour window.
    ///
    /// If the window entry is absent, returns 0.
    /// `window_index = (now - season_start_ts) / 21600`
    #[view]
    public fun get_merch_sold_window(
        merch_type_id: u64, window_index: u64
    ): u64 acquires MerchCounters {
        let mc = borrow_global<MerchCounters>(admin_addr());
        let window_key = merch_type_id * MERCH_TYPE_ID_MULTIPLIER + window_index;
        if (Table::contains(&mc.window_merch_sold, window_key)) {
            *Table::borrow(&mc.window_merch_sold, window_key)
        } else { 0 }
    }

    /// View: returns the full `MerchType` struct for a given merch type ID.
    /// Includes name, price, max per-user, and total sold.
    #[view]
    public fun get_all_merch_details(): vector<Merch> acquires MerchTable {
        let mtl = borrow_global<MerchTable>(admin_addr());
        let len = vector::length(&mtl.type_ids);
        let merch_vec = vector::empty<Merch>();
        while (len > 0) {
            let merch_type_id = vector::borrow(&mtl.type_ids, len - 1);
            let merch_type = Table::borrow(&mtl.items, *merch_type_id);
            vector::push_back(&mut merch_vec, *merch_type);
            len = len - 1;
        };

        // let merch_type = Table::borrow(&mtl.items, merch_type_id);
        merch_vec
    }

    #[view]
    public fun check_vrf_sent_randomness(crate_id: u64): bool acquires RandomNumberList, NonceEntry {
        let nonce_entry = borrow_global<NonceEntry>(admin_addr());
        if (!Table::contains(&nonce_entry.crate_nonce, crate_id)) {
            return false;
        };
        let nonce = Table::borrow(&nonce_entry.crate_nonce, crate_id);

        let tbl = borrow_global<RandomNumberList>(@ZAPSHOP);
        Table::contains(&tbl.list, *nonce)
    }

    /// View: returns the next 6-hour merch sale window timestamp.
    ///
    /// If before season, returns `season_start_ts`.
    /// If after season, returns `0`.
    /// Otherwise, returns the next window boundary (every 21600 seconds).
    #[view]
    public fun get_next_merch_sale_timestamp(): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr());
        let now = timestamp::now_seconds();
        if (now < cfg.season_start_ts) {
            cfg.season_start_ts
        } else if (now > cfg.season_end_ts) { 0 }
        else {
            let window_index = (now - cfg.season_start_ts) / 21600; // 6 hours = 21600s
            cfg.season_start_ts + (window_index + 1) * 21600
        }
    }

    // ********* MISC VIEWS ********** //

    /// View: returns the resource account address derived for this module.
    ///
    /// This is the address used for VRF resource signer capability creation.
    #[view]
    public fun get_resource_address(): address {
        account::create_resource_address(&@ZAPSHOP, RESOURCE_ADDRESS_SEED)
    }

    /// View: returns (raffle IDs, crate IDs, merch type IDs) for a user.
    ///
    /// Useful for frontends to load a users full inventory in a single call.
    #[view]
    public fun get_user_inventory_details(
        user: address
    ): (vector<u64>, vector<u64>, vector<u64>) acquires Inventory {
        let inv = borrow_global<Inventory>(user);
        (inv.raffle_ids, inv.crate_ids, inv.merch_type_ids)
    }

    #[view]
    public fun get_user_inventory_full(
        user: address
    ): (vector<u64>, vector<Crate>, vector<UserMerch>) acquires Inventory {
        assert!(exists<Inventory>(user), E_USER_NOT_REGISTERED);
        let inv = borrow_global<Inventory>(user);
        let len = vector::length(&inv.crate_ids);
        let crates_vec = vector::empty<Crate>();
        while (len > 0) {
            let crate_ref =
                Table::borrow(&inv.crates, *vector::borrow(&inv.crate_ids, len - 1));
            vector::push_back(&mut crates_vec, *crate_ref);
            len = len - 1;
        };

        let lenn = vector::length(&inv.merch_type_ids);
        let merch_vec = vector::empty<UserMerch>();
        while (lenn > 0) {
            let merch_type_id = *vector::borrow(&inv.merch_type_ids, lenn - 1);
            if (Table::contains(&inv.merch, merch_type_id)) {
                let um = *Table::borrow(&inv.merch, merch_type_id);
                vector::push_back(&mut merch_vec, um);
            };
            lenn = lenn - 1;
        };

        (inv.raffle_ids, crates_vec, merch_vec)
    }

    #[view]
    public fun get_zap_balance(user: address): u64 {
        coin::balance<ZAP>(user)
    }

    /// View: returns whether all user resources exist (Inventory, UserDayCounters, UserMerchCap).
    #[view]
    public fun check_exists_user(user: address): bool {
        exists<Inventory>(user)
            && exists<UserDayCounters>(user)
            && exists<UserMerchCap>(user)
    }

    #[view]
    public fun check_exists_merch_type(merch_type_id: u64): bool acquires MerchTable {
        let mtl = borrow_global<MerchTable>(admin_addr());
        Table::contains(&mtl.items, merch_type_id)
    }
}

// let resource_signer_cap = borrow_global<ResourceSignerCap>(@ZAPSHOP);
// let resource_signer =
//     account::create_signer_with_capability(&resource_signer_cap.signer_cap);
