import fs from "node:fs";
import path from "node:path";
import solc from "solc";

const sourcePath = path.resolve("src/CreditTerminal.sol");
const source = fs.readFileSync(sourcePath, "utf8");
const testSource = fs.readFileSync(path.resolve("test/CreditTerminal.t.sol"), "utf8");
const input = {
  language: "Solidity",
  sources: { "CreditTerminal.sol": { content: source }, "CreditTerminal.t.sol": { content: testSource } },
  settings: { evmVersion: "paris", optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
};
const output = JSON.parse(solc.compile(JSON.stringify(input)));
for (const error of output.errors ?? []) console.error(error.formattedMessage);
if ((output.errors ?? []).some((e) => e.severity === "error")) process.exit(1);
fs.writeFileSync("test/compiled.json", JSON.stringify(output.contracts["CreditTerminal.sol"]));
console.log(`Compiled source and Foundry tests (${Object.keys(output.contracts["CreditTerminal.sol"]).length} contracts) with solc ${solc.version()}`);