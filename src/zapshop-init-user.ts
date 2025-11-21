import "dotenv/config";
import {
  HexString,
  SupraAccount,
  SupraClient,
  BCS
} from "supra-l1-sdk";
import { Buffer } from "buffer";
import { readFile } from "fs/promises";
import { existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Type for user data
interface UserData {
  address: string;
  zapBalance: string | number; // Can be string or number, will be converted to BigInt
}

// Function to load users from JSON file
async function loadUsersFromFile(filePath: string): Promise<UserData[]> {
  try {
    if (!existsSync(filePath)) {
      throw new Error(`File not found: ${filePath}`);
    }

    const fileContent = await readFile(filePath, "utf-8");
    const data = JSON.parse(fileContent);

    // Support both array format and object with users array
    let users: UserData[];
    if (Array.isArray(data)) {
      users = data;
    } else if (data.users && Array.isArray(data.users)) {
      users = data.users;
    } else {
      throw new Error("Invalid JSON format. Expected array or object with 'users' array.");
    }

    // Validate each user entry
    users.forEach((user, index) => {
      if (!user.address) {
        throw new Error(`User at index ${index} is missing 'address' field`);
      }
      if (user.zapBalance === undefined || user.zapBalance === null) {
        throw new Error(`User at index ${index} is missing 'zapBalance' field`);
      }
    });

    return users;
  } catch (error) {
    throw new Error(`Failed to load users from file: ${error}`);
  }
}

// Function to initialize a single user
async function initializeUser(
  supraClient: SupraClient,
  adminAccount: SupraAccount,
  contractAddress: string,
  userAddress: string,
  zapBalance: bigint,
  checkFunctionFullName: string
): Promise<{ success: boolean; error?: string; txHash?: string }> {
  try {
    // Check if user is already initialized
    try {
      const checkResult = await supraClient.invokeViewMethod(
        checkFunctionFullName,
        [],
        [userAddress]
      );

      const [isInitiated, currentBalance] = checkResult as [boolean, string | number];

      if (isInitiated) {
        return {
          success: false,
          error: `Already initialized with balance: ${currentBalance}`
        };
      }
    } catch (error) {
      // If check fails, proceed anyway
      console.log(`  ⚠️  Could not check user status, proceeding...`);
    }

    // Get account info to get sequence number
    const accountInfo = await supraClient.getAccountInfo(adminAccount.address());

    // Parse the function string
    const functionFullName = `${contractAddress}::zap_shop_v1::user_init_zap_snapshot`;
    const parts = functionFullName.split("::");
    if (parts.length !== 3) {
      throw new Error(`Invalid function format: ${functionFullName}`);
    }
    const [moduleAddr, moduleName, functionName] = parts;

    // Convert user address to HexString and then to Uint8Array for serialization
    const userAddressHex = new HexString(userAddress);

    // Serialize arguments using BCS
    const functionArgs = [
      userAddressHex.toUint8Array(),
      BCS.bcsSerializeUint64(zapBalance)
    ];

    // Create serialized raw transaction object
    const serializedRawTxn = await supraClient.createSerializedRawTxObject(
      adminAccount.address(),
      accountInfo.sequence_number,
      moduleAddr!,
      moduleName!,
      functionName!,
      [],
      functionArgs,
      {}
    );

    // Send the transaction
    const txResData = await supraClient.sendTxUsingSerializedRawTransaction(
      adminAccount,
      serializedRawTxn,
      {
        enableWaitForTransaction: true,
        enableTransactionSimulation: true,
      }
    );

    return {
      success: true,
      txHash: txResData.txHash
    };
  } catch (error: any) {
    return {
      success: false,
      error: error.message || String(error)
    };
  }
}


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
  const checkFunctionFullName = `${CONTRACT_ADDRESS}::zap_shop_v1::check_user_initiated`;

  // Load users from file (default: users.json in project root)
  const usersFilePath = process.env.USERS_FILE || join(__dirname, "../users.json");
  console.log(`\n📁 Loading users from: ${usersFilePath}`);

  let users: UserData[];
  try {
    users = await loadUsersFromFile(usersFilePath);
    console.log(`✓ Loaded ${users.length} user(s) from file\n`);
  } catch (error: any) {
    console.error(`❌ Error loading users file: ${error.message}`);
    console.log(`\n💡 Create a users.json file with the following format:`);
    console.log(`[
  {
    "address": "0x...a",
    "zapBalance": "50000000"
  },
  {
    "address": "0x...",
    "zapBalance": "100000000"
  }
]`);
    process.exit(1);
  }

  // Process each user
  console.log("🚀 Starting batch initialization...\n");
  const results: Array<{ user: UserData; success: boolean; error?: string; txHash?: string }> = [];

  for (let i = 0; i < users.length; i++) {
    const user = users[i]!;
    const userAddress = user.address.trim();
    const zapBalance = BigInt(String(user.zapBalance));

    console.log(`[${i + 1}/${users.length}] Processing: ${userAddress}`);
    console.log(`  ZAP Balance: ${zapBalance}`);

    const result = await initializeUser(
      supraClient,
      adminAccount,
      CONTRACT_ADDRESS,
      userAddress,
      zapBalance,
      checkFunctionFullName
    );

    if (result.success) {
      console.log(`  ✅ Success! Transaction: ${result.txHash || "N/A"}`);
      results.push({
        user,
        success: true,
        ...(result.txHash && { txHash: result.txHash })
      });
    } else {
      console.log(`  ❌ Failed: ${result.error || "Unknown error"}`);
      results.push({
        user,
        success: false,
        ...(result.error && { error: result.error })
      });
    }

    // Small delay between transactions to avoid rate limiting
    if (i < users.length - 1) {
      await new Promise(resolve => setTimeout(resolve, 1000)); // 1 second delay
    }

    console.log(""); // Empty line for readability
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("📊 BATCH INITIALIZATION SUMMARY");
  console.log("=".repeat(60));
  const successful = results.filter(r => r.success).length;
  const failed = results.filter(r => !r.success).length;
  console.log(`Total users: ${users.length}`);
  console.log(`✅ Successful: ${successful}`);
  console.log(`❌ Failed: ${failed}`);
  console.log("\nDetails:");

  results.forEach((result, index) => {
    const status = result.success ? "✅" : "❌";
    console.log(`  ${status} [${index + 1}] ${result.user.address.substring(0, 20)}...`);
    if (result.success && result.txHash) {
      console.log(`      TX: ${result.txHash}`);
    } else if (result.error) {
      console.log(`      Error: ${result.error}`);
    }
  });
  console.log("=".repeat(60) + "\n");

})();

