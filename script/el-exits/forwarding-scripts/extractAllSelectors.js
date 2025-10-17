const fs = require("fs");

function extractSelectors(filePath, eventSignature) {
  const content = fs.readFileSync(filePath, "utf8");
  const regex = /0x[0-9a-fA-F]{64}/g;
  
  let match;
  const selectors = new Set();
  
  while ((match = regex.exec(content)) !== null) {
    const fullTopic = match[0];
    
    if (fullTopic.toLowerCase().startsWith(eventSignature)) continue;
    
    const selector = "0x" + fullTopic.slice(2, 10);
    selectors.add(selector);
  }
  
  return selectors;
}

const externalSelectors = extractSelectors(
  "script/forwarding-scripts/events_AllowedForwardedExternalCallsUpdated.txt", 
  "0xf8fbe92f" // AllowedForwardedExternalCallsUpdated event signature
);

const eigenpodSelectors = extractSelectors(
  "script/forwarding-scripts/events_AllowedForwardedEigenpodCallsUpdated.txt", 
  "0xf8fbe92f" // AllowedForwardedEigenpodCallsUpdated event signature
);

const output = [
  "// ========================================",
  "// ALLOWED FORWARDED EXTERNAL CALLS SELECTORS",
  "// ========================================",
  "// Function: updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed)",
  "",
  ...Array.from(externalSelectors).map(sel => `${sel}`),
  "",
  "// ========================================",
  "// ALLOWED FORWARDED EIGENPOD CALLS SELECTORS", 
  "// ========================================",
  "// Function: updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed)",
  "",
  ...Array.from(eigenpodSelectors).map(sel => `${sel}`),
  "",
  "// ========================================",
  "// SUMMARY",
  "// ========================================",
  `// External calls selectors: ${externalSelectors.size}`,
  `// Eigenpod calls selectors: ${eigenpodSelectors.size}`,
  `// Total selectors: ${externalSelectors.size + eigenpodSelectors.size}`
].join("\n");

fs.writeFileSync("script/forwarding-scripts/selectors.txt", output, "utf8");

console.log(`Generated selectors.txt with ${externalSelectors.size} external and ${eigenpodSelectors.size} eigenpod selectors`);
