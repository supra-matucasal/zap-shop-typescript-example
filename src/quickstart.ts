import {
    HexString,
    SupraAccount,
    SupraClient
  } from "supra-l1-sdk";
import { Buffer } from "buffer";
  
  (async () => {        
  
    // To Create Instance Of Supra Client, But In This Method We Don't Need To Pass ChainId.
    // ChainId Will Be Identified At Instance Creation Time By Making RPC Call.
    let supraClient = await SupraClient.init(
      "https://rpc-testnet.supra.com"
    );
  
    //Init a SupraAccount from a private key.
    let senderAccount = new SupraAccount(
      Uint8Array.from(
        Buffer.from(
          "2b9654793a999d1d487dabbd1b8f194156e15281fa1952af121cc97b27578d89",
          "hex"
        )
      )
    );

    //Fund the sender account with the testnet faucet
    await supraClient.fundAccountWithFaucet(senderAccount.address())

    //Set the receiver address
    let receiverAddress = new HexString(
      "0xb8922417130785087f9c7926e76542531b703693fdc74c9386b65cf4427f4e80"
    );

    // To Transfer Supra Coin From Sender To Receiver
    let txResData = await supraClient.transferSupraCoin(
      senderAccount,
      receiverAddress,
      BigInt(1000),
      {
        enableTransactionWaitAndSimulationArgs: {
          enableWaitForTransaction: true,
          enableTransactionSimulation: true,
        },
      }
    );

    //Output the transaction data
    console.log("Transfer SupraCoin TxRes: ", txResData);

  })();