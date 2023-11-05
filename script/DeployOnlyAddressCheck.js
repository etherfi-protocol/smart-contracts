const fs = require('fs');
const ethers = require('ethers');
require('dotenv').config();

/*
how to run:
1. Create .env file where:
 ETHERSCAN_API_KEY=<API KEY>, MAINNET_ADDRESS_PROVIDER=0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848, and GOERLI_ADDRESS_PROVIDER=0x6E429db4E1a77bCe9B6F9EDCC4e84ea689c1C97e
2. need ethers, dotenv, and fs modules installed
 3. Write config file: node DeployOnlyAddressCheck.js -write
 4. Validate that the config file is correct
 5. To check addresses: node DeployOnlyAddressCheck.js <network> (network is optional, defaults to mainnet)
*/

function getContractNames() {
  const contracts = fs.readFileSync('contracts.json',
    { encoding: 'utf8', flag: 'r' });
  var arr = JSON.parse(contracts);
  return arr
}

function getABI(fileName) {
  abiDirectory = "../release/abis"
  const files = fs.readdirSync(abiDirectory)
  var arr = []
  retval = ""
  for (const file of files) {
    if (String(fileName + ".json").toLowerCase() == String(file).toLowerCase()) {
      abi = fs.readFileSync(abiDirectory + "/" + file,
        { encoding: 'utf8', flag: 'r' });
      retval = abi
      break
    }
  }
  return retval
}

async function callMethod(contractAddress, abi, functionName, args, network) {
  let provider = new ethers.providers.EtherscanProvider(network, process.env.ETHERSCAN_API_KEY)
  let contract = new ethers.Contract(contractAddress, abi, provider);
  return await contract[functionName](...args).catch((err) => {
    console.log("ERROR CALLING METHOD " + functionName)
  })
}

function contractSubstring(method, contracts) {
  for (contract of contracts) {
    if (method.toLowerCase() == contract.toLowerCase()) return contract
  }
  for (contract of contracts) {
    meth = method.toLowerCase()
    con = contract.toLowerCase()
    if (meth.includes(con) || con.includes(meth)) {
      return contract
    }
  }
  return ""
}

function isDeprecated(method) {
  return (method.toLowerCase().includes("deprecated"))
}

function writeConfigFile() {
  contracts = getContractNames()
  jsonConfig = {}

  for (contract of contracts) {
    arr = []
    jsonConfig[contract] = { arr };
  }
  contracts.forEach(contract => {
    abi = getABI(contract)
    abi = JSON.parse(abi)
    methods = []
    for (let i = 0; i < abi.length; i++) {
      method = abi[i]
      if (method["type"] != undefined && method["stateMutability"] != undefined) {
        if (method["type"] == "function" && method["stateMutability"] == "view" &&
          method["inputs"].length == 0 && method["outputs"].length == 1 && method["outputs"][0]["type"] == "address" && !isDeprecated(method["name"])) { //check if returns address
          methodSubstring = contractSubstring(method["name"], contracts)
          if (methodSubstring != "") {
            methods.push({
              "methodName": method["name"],
              "value": methodSubstring,
              "isReference": true
            })
          }
        }
      }
    }
    jsonConfig[contract] = methods
  })
  const filePath = 'addressConfig.json';
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(filePath, JSON.stringify(jsonConfig));
  } else {
    console.log('File already exists');
  }
}

async function checkFunctionAddress(network) {
  const file = fs.readFileSync('addressConfig.json',
    { encoding: 'utf8', flag: 'r' });
  var contract_Methods = JSON.parse(file);
  contracts = getContractNames()
  contract_address = {}
  addressProvider = ""

  if (network == "mainnet") addressProvider = process.env.MAINNET_ADDRESS_PROVIDER
  else if (network == "goerli") addressProvider = process.env.GOERLI_ADDRESS_PROVIDER
  addressProviderABI = getABI("AddressProvider")
  addyProviderFunName = "getContractAddress"

  for (contract of contracts) { //populate map of contract addresses
    var addy = await callMethod(addressProvider, addressProviderABI, addyProviderFunName, [contract], network)
    contract_address[contract] = addy
  }
  for (contract of contracts) {
    methods = contract_Methods[contract]
    for (method of methods) {
      if (method["value"] != "" && method["isReference"] == true) {
        address = await callMethod(contract_address[contract], getABI(contract), method["methodName"], [], network)
        if (address != contract_address[method["value"]]) {
          console.log("contract:" + contract + " method:" + method["methodName"] + " address:" + address + " correct address:" + contract_address[method["value"]])
        }
      }
    }
  }
}

async function main() {
  const args = process.argv;
  network = "mainnet"
  if (args.length > 2) {
    if (args[2] == "-write") {
      writeConfigFile()
      return
    } else { //assume network
      network = args[2]
    }
  }
  checkFunctionAddress(network)
}

main()

