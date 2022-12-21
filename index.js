const fs = require("fs");
const {
  TokenCreateTransaction,
  Client,
  PrivateKey,
  TokenInfoQuery,
  FileCreateTransaction,
  FileAppendTransaction,
  Hbar,
  ContractCreateTransaction,
  ContractFunctionParameters,
  ContractExecuteTransaction,
  AccountId,
  ContractCallQuery,
  TokenType,
  AccountCreateTransaction,
  TokenAssociateTransaction,
  TransferTransaction,
} = require("@hashgraph/sdk");
const dotenv = require("dotenv");
dotenv.config();

const myAccountId = AccountId.fromString(process.env.ACCOUNT_ID);
const myPrivateKey = PrivateKey.fromString(process.env.PRIVATE_KEY);
let contractId;

// The Hedera JS SDK makes this really easy!
const client = Client.forTestnet();
client.setOperator(myAccountId, myPrivateKey);

async function tQueryFcn(tId) {
  let info = await new TokenInfoQuery().setTokenId(tId).execute(client);
  return info;
}

async function balanceOf(address) {
  let contractExecTx = await new ContractCallQuery()
    .setContractId(contractId)
    .setGas(100000)
    .setFunction(
      "balanceOf",
      new ContractFunctionParameters().addAddress(address.toSolidityAddress())
    )
    .setQueryPayment(new Hbar(10));
  let contractExecSubmit = await contractExecTx.execute(client);
  return contractExecSubmit.getUint256(0).toString();
}

const main = async () => {
  // STEP 1 ===================================
  console.log(`STEP 1 ===== Create native token and an account ========`);
  //Create a fungible token
  const tokenCreateTx = await new TokenCreateTransaction()
    .setTokenName("Revive")
    .setTokenSymbol("REV")
    .setTokenType(TokenType.FungibleCommon)
    .setDecimals(8)
    .setInitialSupply(1000000000000000000)
    .setTreasuryAccountId(myAccountId)
    .setAdminKey(myPrivateKey)
    .setSupplyKey(myPrivateKey)
    .freezeWith(client)
    .sign(myPrivateKey);
  const tokenCreateSubmit = await tokenCreateTx.execute(client);
  const tokenCreateRx = await tokenCreateSubmit.getReceipt(client);
  const tokenId = tokenCreateRx.tokenId; //TokenId.fromString("0.0.34891622"); //
  const tokenAddressSol = tokenId.toSolidityAddress();
  console.log(`- Token ID: ${tokenId}`);
  console.log(`- Token ID in Solidity format: ${tokenAddressSol}`);

  // Token query 1
  const tokenInfo1 = await tQueryFcn(tokenId);
  console.log(`- Initial token supply: ${tokenInfo1.totalSupply.low}`);

  //Create the transaction
  const newAccountPrivateKey = await PrivateKey.generateED25519();
  const transaction = new AccountCreateTransaction()
    .setKey(newAccountPrivateKey.publicKey)
    .setInitialBalance(new Hbar(10));

  //Sign the transaction with the client operator private key and submit to a Hedera network
  const txResponse = await transaction.execute(client);
  //Request the receipt of the transaction
  const receipt = await txResponse.getReceipt(client);

  //Get the account ID
  const newAccountId = receipt.accountId;
  console.log("- The new account ID is " + newAccountId);
  client.setOperator(newAccountId, newAccountPrivateKey);
  let associateAccount = await new TokenAssociateTransaction()
    .setAccountId(newAccountId)
    .setTokenIds([tokenId]);
  let associateAccountTxSubmit = await associateAccount.execute(client);
  let associateAccountRx = await associateAccountTxSubmit.getReceipt(client);
  console.log(
    `- Token association with new account: ${associateAccountRx.status}\n`
  );
  client.setOperator(myAccountId, myPrivateKey);

  // STEP 2 ===================================
  console.log(`STEP 2 ===== Deploy Solidity contract ==============`);
  // Create the smart contract
  // Create a file on Hedera and store the hex-encoded bytecode
  const bytecode = fs.readFileSync("./Revive_sol_Revive.bin");
  const fileCreateTx = new FileCreateTransaction().setKeys([myPrivateKey]);
  const fileSubmit = await fileCreateTx.execute(client);
  const fileCreateRx = await fileSubmit.getReceipt(client);
  const bytecodeFileId = fileCreateRx.fileId;
  console.log(`- The smart contract bytecode file ID is: ${bytecodeFileId}`);

  // Append contents to the file
  const fileAppendTx = new FileAppendTransaction()
    .setFileId(bytecodeFileId)
    .setContents(bytecode)
    .setMaxChunks(5)
    .setMaxTransactionFee(new Hbar(2));
  const fileAppendSubmit = await fileAppendTx.execute(client);
  const fileAppendRx = await fileAppendSubmit.getReceipt(client);
  console.log(`- Content added: ${fileAppendRx.status}`);

  const contractInstantiateTx = new ContractCreateTransaction()
    .setBytecodeFileId(bytecodeFileId)
    .setGas(3000000)
    .setConstructorParameters(
      new ContractFunctionParameters().addAddress(tokenAddressSol)
    );
  const contractInstantiateSubmit = await contractInstantiateTx.execute(client);
  const contractInstantiateRx = await contractInstantiateSubmit.getReceipt(
    client
  );
  contractId = contractInstantiateRx.contractId;
  const contractAddress = contractId.toSolidityAddress();
  console.log(`- The smart contract ID is: ${contractId}`);
  console.log(
    `- The smart contract ID in Solidity format is: ${contractAddress}`
  );

  let contractQuery = await new ContractCallQuery()
    .setGas(100000)
    .setContractId(contractId)
    .setFunction("tokenAddress")
    .setQueryPayment(new Hbar(10));

  let getMessage = await contractQuery.execute(client);
  console.log(
    `- Current tokenAddress ${getMessage.getAddress(0).toString()}\n`
  );

  // STEP 3 ===================================
  // Get balanceOf current account
  console.log(`STEP 3 ===== Check balances ===================`);
  //Execute a contract function (mint)
  console.log(`- My balance: ${await balanceOf(myAccountId)}`);
  console.log(`- New account balance: ${await balanceOf(newAccountId)}\n`);

  // STEP 4 ===================================
  // Transfer tokens
  console.log(`STEP 4 ===== Transfer tokens ================`);

  let transferTx = await new ContractExecuteTransaction()
    .setGas(4000000)
    .setContractId(contractId)
    .setMaxTransactionFee(Hbar.from(10))
    .setFunction(
      "transfer",
      new ContractFunctionParameters()
        .addAddress(newAccountId.toSolidityAddress())
        .addUint256(200)
    );

  let transferRx = await transferTx.execute(client);
  let txResult = await transferRx.getReceipt(client);
  console.log(`- Transfer 200 tokens to new account status ${txResult.status}`);
  console.log(`- My balance: ${await balanceOf(myAccountId)}`);
  console.log(`- New account balance: ${await balanceOf(newAccountId)}\n`);

  // STEP 5 ===================================
  // Approve and transferFrom
  console.log(`STEP 5 ===== Approve and transferFrom ================`);
  transferTx = await new ContractExecuteTransaction()
    .setGas(4000000)
    .setContractId(contractId)
    .setMaxTransactionFee(Hbar.from(10))
    .setFunction(
      "approve",
      new ContractFunctionParameters()
        .addAddress(newAccountId.toSolidityAddress())
        .addUint256(200)
    );

  transferRx = await transferTx.execute(client);
  txResult = await transferRx.getReceipt(client);
  console.log(
    `- Approve 200 tokens for the new account status ${txResult.status}`
  );

  client.setOperator(newAccountId, newAccountPrivateKey);
  transferTx = await new ContractExecuteTransaction()
    .setGas(4000000)
    .setContractId(contractId)
    .setMaxTransactionFee(Hbar.from(10))
    .setFunction(
      "transferFrom",
      new ContractFunctionParameters()
        .addAddress(myAccountId.toSolidityAddress())
        .addAddress(newAccountId.toSolidityAddress())
        .addUint256(200)
    );

  transferRx = await transferTx.execute(client);
  txResult = await transferRx.getReceipt(client);
  console.log(
    `- TransferFrom 200 tokens to new account status ${txResult.status}`
  );

};

main();