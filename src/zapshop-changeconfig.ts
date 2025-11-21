import "dotenv/config";
import {
    SupraAccount,
    SupraClient,
    BCS
  } from "supra-l1-sdk";
import { Buffer } from "buffer";

  
  (async () => {      
    
    const zapshopAddress = process.env.ZAPSHOP_ADDRESS || "0x..."
    const zapshopPrivateKey = process.env.ZAPSHOP_PRIVATE_KEY || "abc"
    const supraRpc = process.env.SUPRA_RPC || "https://rpc-testnet.supra.com"
  
    // Validate and normalize private key
    // Ed25519 private keys must be exactly 32 bytes (64 hex characters)
    let normalizedPrivateKey = zapshopPrivateKey.trim();
    
    // Remove "0x" prefix if present
    if (normalizedPrivateKey.startsWith("0x") || normalizedPrivateKey.startsWith("0X")) {
      normalizedPrivateKey = normalizedPrivateKey.slice(2);
    }
    
    // Validate length (must be 64 hex characters = 32 bytes)
    if (normalizedPrivateKey.length !== 64) {
      throw new Error(
        `Invalid private key length. Expected 64 hex characters (32 bytes), got ${normalizedPrivateKey.length}.\n` +
        `Private key must be exactly 64 hex characters (with or without 0x prefix).\n` +
        `Current key: ${normalizedPrivateKey.substring(0, 20)}... (length: ${normalizedPrivateKey.length})`
      );
    }
    
    // Validate it's valid hex
    if (!/^[0-9a-fA-F]{64}$/.test(normalizedPrivateKey)) {
      throw new Error(
        `Invalid private key format. Must be a valid hexadecimal string (64 characters).\n` +
        `Received: ${normalizedPrivateKey.substring(0, 20)}...`
      );
    }

    // To Create Instance Of Supra Client, But In This Method We Don't Need To Pass ChainId.
    // ChainId Will Be Identified At Instance Creation Time By Making RPC Call.
    let supraClient = await SupraClient.init(
      supraRpc
    );
  
    // Init a SupraAccount from a private key (admin account)
    // The private key must be exactly 32 bytes (64 hex characters, without 0x prefix)
    let adminAccount: SupraAccount;
    try {
      const privateKeyBytes = Buffer.from(normalizedPrivateKey, "hex");
      
      if (privateKeyBytes.length !== 32) {
        throw new Error(`Private key must be exactly 32 bytes, got ${privateKeyBytes.length}`);
      }
      
      adminAccount = new SupraAccount(Uint8Array.from(privateKeyBytes));
      console.log(`✓ Successfully initialized account from private key`);
      console.log(`  Account address: ${adminAccount.address()}`);
    } catch (error) {
      throw new Error(
        `Failed to create SupraAccount from private key: ${error}\n` +
        `Make sure the private key is a valid 64-character hex string (32 bytes).\n` +
        `Normalized key: ${normalizedPrivateKey.substring(0, 20)}...`
      );
    }

    // Contract address
    const CONTRACT_ADDRESS = zapshopAddress;
    
    // Parse the function string: "0x...::zap_shop_v1::change_crate_opening_timeslots"
    const functionFullName = `${CONTRACT_ADDRESS}::zap_shop_v1::change_crate_opening_timeslots`;
    const parts = functionFullName.split("::");
    if (parts.length !== 3) {
      throw new Error(`Invalid function format: ${functionFullName}. Expected format: "address::module::function"`);
    }
    const moduleAddr = parts[0]!;
    const moduleName = parts[1]!;
    const functionName = parts[2]!;
    
    // Get account info to get sequence number
    const accountInfo = await supraClient.getAccountInfo(adminAccount.address());
    
    // Prepare function arguments (u64 timestamps)
    const openM1 = BigInt("1762764778");  // M1 - keeping current (or set your desired M1 time)
    const openM2 = BigInt("1767225600");  // M2 - January 1, 2026
    const openM3 = BigInt("1769904000");  // M3 - February 1, 2026
    
    // Serialize arguments using BCS
    const functionArgs = [
      BCS.bcsSerializeUint64(openM1),
      BCS.bcsSerializeUint64(openM2),
      BCS.bcsSerializeUint64(openM3)
    ];
    
    // Create serialized raw transaction object
    const serializedRawTxn = await supraClient.createSerializedRawTxObject(
      adminAccount.address(),
      accountInfo.sequence_number,
      moduleAddr,
      moduleName,
      functionName,
      [], // type_arguments (empty array)
      functionArgs,
      {
        // Optional transaction payload args
        // maxGas: BigInt(10000),
        // gasUnitPrice: BigInt(100),
        // txExpiryTime: BigInt(Math.floor(Date.now() / 1000) + 300) // 5 minutes from now
      }
    );
    
    // Send the transaction (this method signs internally)
    const txResData = await supraClient.sendTxUsingSerializedRawTransaction(
      adminAccount,
      serializedRawTxn,
      {
        enableWaitForTransaction: true,
        enableTransactionSimulation: true,
      }
    );

    // Output the transaction data
    console.log("Change Crate Opening Timeslots TxRes: ", txResData);

  })();