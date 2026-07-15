import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  formatUnits,
  getAddress,
  hashTypedData,
  http,
  keccak256,
  parseUnits,
  toHex,
  type Address,
  type Chain,
  type EIP1193Provider,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { acceptedResultTypes, erc20Abi, escrowAbi } from "./abi";
import {
  ZERO_ADDRESS,
  assertAttestationReady,
  computeSolverCommitment as computeCommitmentLocally,
  copyConfig,
  dateTimeLocalToSeconds,
  downloadJson,
  explainBountyStatus,
  formatTimestamp,
  hashExactBytes,
  hashExactText,
  normalizeManifest,
  randomSalt,
  requireAddress,
  requireNonzeroBytes32,
  requirePositiveInteger,
  requireSignature,
  secondsToDateTimeLocal,
  shortHex,
  suggestedVerifierFee,
} from "./lib";
import type { AppConfig, BountyView, ClaimPackage, DeploymentChoice } from "./types";
import "./styles.css";

const root = document.querySelector<HTMLDivElement>("#app");
if (!root) throw new Error("Application root is missing.");
if (window.top !== window.self) {
  document.body.textContent = "This wallet interface refuses to run inside a frame. Open it directly from its authenticated origin.";
  throw new Error("Framed execution refused.");
}

root.innerHTML = `
  <header class="site-header">
    <div>
      <p class="eyebrow">Immutable, chain-local escrow</p>
      <h1>Proof Bounty Escrow</h1>
      <p class="lede">Create, solve, attest, and settle objective proof bounties without a hosted backend.</p>
    </div>
    <div class="wallet-box">
      <span id="wallet-state" class="status-dot">Wallet not connected</span>
      <div class="button-row compact">
        <button id="connect-wallet" type="button">Connect wallet</button>
        <button id="switch-chain" class="secondary" type="button">Switch chain</button>
      </div>
    </div>
  </header>

  <aside class="privacy-banner">
    <strong>Privacy boundary:</strong> this build has no server, telemetry, analytics, cookies, or remote runtime assets. Your wallet, chosen RPC, public mempool, and any IPFS gateway can still learn your IP address and correlate it with public on-chain activity. Never put secrets or personal data in a manifest, hash preimage, transaction, or RPC URL.
  </aside>

  <section class="panel setup-panel">
    <div class="section-heading">
      <div>
        <p class="eyebrow">Step 1</p>
        <h2>Choose and verify a deployment</h2>
      </div>
      <span id="deployment-state" class="pill muted">Not verified</span>
    </div>

    <div class="manifest-row">
      <label class="wide">Bundled or imported manifest
        <select id="deployment-choice"><option value="">Manual configuration</option></select>
      </label>
      <label class="file-button">Import manifest JSON
        <input id="manifest-file" type="file" accept="application/json,.json" />
      </label>
    </div>

    <div class="form-grid config-grid">
      <label>Network label <input id="network-name" value="Custom EVM" autocomplete="off" /></label>
      <label>Chain ID <input id="chain-id" value="943" inputmode="numeric" autocomplete="off" /></label>
      <label class="wide">RPC URL <input id="rpc-url" type="url" placeholder="Optional when using the injected wallet provider" autocomplete="off" spellcheck="false" /></label>
      <label class="wide">Escrow contract <input id="contract-address" placeholder="0x…" autocomplete="off" spellcheck="false" /></label>
      <label>Variant
        <select id="variant"><option value="native">Native currency</option><option value="erc20">ERC-20</option></select>
      </label>
      <label>Native symbol <input id="native-symbol" value="NATIVE" maxlength="12" autocomplete="off" /></label>
      <label>Native decimals <input id="native-decimals" value="18" inputmode="numeric" autocomplete="off" /></label>
    </div>
    <p class="field-note">Leave RPC blank to route reads through the injected wallet. A custom RPC enables read-only use without connecting an account, but the RPC operator sees requests. Configuration remains in memory and is not saved.</p>
    <div class="button-row">
      <button id="apply-config" type="button">Verify deployment</button>
    </div>
    <label id="untrusted-ack-box" class="trust-ack hidden">
      <input id="untrusted-ack" type="checkbox" />
      <span>I independently authenticated this exact chain, contract, runtime code hash, asset, fee recipients, and verifier set. I understand a responsive contract or user-imported JSON is not proof of provenance. Enable wallet writes for this verified target.</span>
    </label>
    <div id="deployment-details" class="deployment-details" aria-live="polite"></div>
  </section>

  <main id="workspace" class="workspace hidden">
    <section class="metrics" aria-label="Deployment overview">
      <article><span>Latest bounty</span><strong id="metric-latest">—</strong></article>
      <article><span>Escrow solvent</span><strong id="metric-solvent">—</strong></article>
      <article><span>Your credit</span><strong id="metric-credit">Connect wallet</strong></article>
      <article><span>Settlement asset</span><strong id="metric-asset">—</strong></article>
    </section>

    <section class="panel">
      <div class="section-heading">
        <div><p class="eyebrow">Public state</p><h2>Browse bounties</h2></div>
        <div class="button-row compact">
          <label class="inline-label">Bounty ID <input id="lookup-id" inputmode="numeric" placeholder="1" /></label>
          <button id="lookup-bounty" class="secondary" type="button">Look up</button>
          <button id="refresh-bounties" type="button">Refresh latest</button>
        </div>
      </div>
      <p class="field-note">The app reads the newest 12 IDs directly from the contract. It does not use an indexer, so it cannot search manifest contents or discover an IPFS CID from a bytes32 hash.</p>
      <div id="bounty-list" class="bounty-list" aria-live="polite"></div>
    </section>

    <details class="panel write-panel" open>
      <summary><span><span class="eyebrow">Sponsor</span>Create a bounty</span></summary>
      <form id="create-form" class="form-grid action-form">
        <label>Advertised reward <span id="reward-symbol" class="unit">asset</span>
          <input id="create-reward" inputmode="decimal" placeholder="100" autocomplete="off" required />
        </label>
        <label>Verifier pool <span id="verifier-symbol" class="unit">asset</span>
          <span class="input-action"><input id="create-verifier-fee" inputmode="decimal" placeholder="Profile-priced amount" autocomplete="off" required /><button id="suggest-verifier-fee" class="secondary" type="button">Use 5%</button></span>
        </label>
        <label>Refund recipient
          <input id="refund-recipient" placeholder="0x…" autocomplete="off" spellcheck="false" required />
        </label>
        <label>Commit deadline (local time)
          <input id="commit-deadline" type="datetime-local" required />
        </label>
        <label>Claim deadline (local time)
          <input id="claim-deadline" type="datetime-local" required />
        </label>
        <label class="wide">Evaluator profile ID (bytes32)
          <input id="profile-id" placeholder="0x + 64 hex characters" autocomplete="off" spellcheck="false" required />
        </label>
        <label class="wide">Specification / exact manifest hash (bytes32)
          <input id="specification-hash" placeholder="keccak256 of the exact published manifest bytes" autocomplete="off" spellcheck="false" required />
        </label>
        <label class="wide">Terms hash (bytes32)
          <input id="terms-hash" placeholder="0x + 64 hex characters" autocomplete="off" spellcheck="false" required />
        </label>
        <div id="funding-quote" class="quote wide">Enter a reward to calculate funding.</div>
        <div id="erc20-approval" class="wide hidden approval-box">
          <p>ERC-20 bounties need an allowance. Approving exactly the quoted funding limits exposure; the token itself must satisfy the escrow's exact-transfer profile.</p>
          <div class="button-row">
            <button id="approve-funding" type="button">Set exact allowance</button>
            <button id="clear-allowance" class="secondary" type="button">Clear allowance</button>
          </div>
        </div>
        <div class="wide warning-box">The verifier pool is an absolute sponsor-chosen budget, not a passive percentage reward. The two signing verifiers each receive floor(pool ÷ 2); an odd smallest-unit remainder goes to the security reserve. Price the evaluator profile's real compute, review time, operational risk, and required independence. The 5% helper is only a starting suggestion. Fixed protocol fees are added separately. Creating a bounty freezes the economics, recipient, deadlines, and all three hashes; there is no sponsor cancellation or admin recovery path.</div>
        <div class="wide button-row"><button type="submit">Create bounty</button></div>
      </form>
    </details>

    <details class="panel write-panel">
      <summary><span><span class="eyebrow">Solver</span>Commit a result</span></summary>
      <form id="commit-form" class="form-grid action-form">
        <label>Bounty ID <input id="commit-bounty-id" inputmode="numeric" required /></label>
        <label class="wide">Result digest (bytes32)
          <input id="commit-result-digest" placeholder="keccak256 of exact result bytes" autocomplete="off" spellcheck="false" required />
        </label>
        <label class="wide">Secret salt (bytes32)
          <span class="input-action"><input id="commit-salt" placeholder="Generate locally or paste" autocomplete="off" spellcheck="false" required /><button id="generate-salt" class="secondary" type="button">Generate</button></span>
        </label>
        <div class="wide output-box"><span>Commitment</span><code id="computed-commitment">Not computed</code></div>
        <div class="wide warning-box">Back up the result digest and salt before sending. Losing either makes a valid claim impossible. Do not disclose them until the commit phase closes. A new commitment from the same solver replaces the old one.</div>
        <div class="wide button-row">
          <button id="compute-commitment" class="secondary" type="button">Compute</button>
          <button id="download-claim-package" class="secondary" type="button" disabled>Download recovery package</button>
          <button type="submit">Submit commitment</button>
        </div>
      </form>
    </details>

    <details class="panel write-panel">
      <summary><span><span class="eyebrow">Verifier-attested settlement</span>Relay a claim</span></summary>
      <div class="manifest-row">
        <label class="file-button">Import solver recovery package
          <input id="claim-package-file" type="file" accept="application/json,.json" />
        </label>
      </div>
      <form id="claim-form" class="form-grid action-form">
        <label>Bounty ID <input id="claim-bounty-id" inputmode="numeric" required /></label>
        <label class="wide">Solver <input id="claim-solver" placeholder="0x…" autocomplete="off" spellcheck="false" required /></label>
        <label class="wide">Result digest <input id="claim-result-digest" placeholder="0x + 64 hex characters" autocomplete="off" spellcheck="false" required /></label>
        <label class="wide">Salt <input id="claim-salt" placeholder="0x + 64 hex characters" autocomplete="off" spellcheck="false" required /></label>
        <label>Verifier index A <input id="verifier-index-a" value="0" inputmode="numeric" required /></label>
        <label class="wide">Verifier signature A <input id="signature-a" placeholder="65-byte ECDSA signature" autocomplete="off" spellcheck="false" required /></label>
        <label>Verifier index B <input id="verifier-index-b" value="1" inputmode="numeric" required /></label>
        <label class="wide">Verifier signature B <input id="signature-b" placeholder="65-byte ECDSA signature" autocomplete="off" spellcheck="false" required /></label>
        <div class="wide output-box"><span>Locally computed EIP-712 digest</span><code id="attestation-digest">Not computed</code></div>
        <div class="wide warning-box">Wallet <code>personal_sign</code> signatures are invalid here. Verifiers must sign the exact EIP-712 <em>AcceptedResult</em> payload, including the frozen solver reward and verifier pool. Anyone may relay the final two signatures, but only the committed solver receives the reward.</div>
        <div class="wide button-row">
          <button id="prepare-attestation" class="secondary" type="button">Prepare verifier request</button>
          <button id="download-attestation" class="secondary" type="button" disabled>Download verifier request</button>
          <button type="submit">Relay claim</button>
        </div>
      </form>
    </details>

    <details class="panel write-panel">
      <summary><span><span class="eyebrow">Permissionless maintenance</span>Refund or withdraw</span></summary>
      <div class="split-actions">
        <form id="refund-form" class="action-form">
          <h3>Mark an expired bounty refundable</h3>
          <p>Anyone can call this after the claim deadline. The full funded amount becomes credit for the immutable refund recipient; the caller receives nothing.</p>
          <label>Bounty ID <input id="refund-bounty-id" inputmode="numeric" required /></label>
          <button type="submit">Refund expired bounty</button>
        </form>
        <form id="withdraw-form" class="action-form">
          <h3>Withdraw your credit</h3>
          <p id="withdraw-available">Connect a wallet to read credit.</p>
          <label>Destination <input id="withdraw-destination" placeholder="0x…" autocomplete="off" spellcheck="false" required /></label>
          <label>Amount <span id="withdraw-symbol" class="unit">asset</span>
            <span class="input-action"><input id="withdraw-amount" inputmode="decimal" required /><button id="withdraw-max" class="secondary" type="button">Max</button></span>
          </label>
          <button type="submit">Withdraw</button>
        </form>
      </div>
    </details>

    <details class="panel">
      <summary><span><span class="eyebrow">Local utility</span>Hash exact content</span></summary>
      <p>This utility computes <code>keccak256</code> locally. Files never leave the browser. For IPFS, hash the exact canonical manifest bytes, publish those same bytes with your own IPFS client, and share the CID out of band—the escrow stores only bytes32.</p>
      <div class="form-grid action-form">
        <label>Send hash to
          <select id="hash-target">
            <option value="specification-hash">Specification hash</option>
            <option value="profile-id">Evaluator profile ID</option>
            <option value="terms-hash">Terms hash</option>
            <option value="commit-result-digest">Solver result digest</option>
          </select>
        </label>
        <label class="file-button">Hash a local file
          <input id="hash-file" type="file" />
        </label>
        <label class="wide">Or hash exact UTF-8 text
          <textarea id="hash-text" rows="4" placeholder="Whitespace and line endings are significant." spellcheck="false"></textarea>
        </label>
        <div class="wide button-row"><button id="hash-text-button" class="secondary" type="button">Hash exact text</button></div>
        <div class="wide output-box"><span>Latest local hash</span><code id="hash-output">—</code></div>
      </div>
    </details>

    <section class="panel limitations">
      <h2>Know what this interface does not do</h2>
      <ul>
        <li>It does not upload, pin, fetch, validate, or index IPFS content.</li>
        <li>It does not decide whether a result is correct; the deployment's fixed verifier set does.</li>
        <li>It does not hide addresses, amounts, timing, hashes, calldata, or withdrawals from the chain.</li>
        <li>It cannot make an unsafe ERC-20 safe. Fee-on-transfer, rebasing, callback-bearing, deceptive, paused, or blacklistable tokens are outside the supported profile.</li>
        <li>It does not independently prove that an address is the intended audited bytecode. Verify the deployment manifest, source revision, runtime code hash, chain, asset, fee recipients, and verifier set before funding it.</li>
      </ul>
    </section>
  </main>

  <div id="notice" class="notice" role="status" aria-live="polite"></div>
  <footer>Static client · no backend · no tracking · configuration is memory-only</footer>
`;

const defaultConfig: AppConfig = {
  networkName: "Custom EVM",
  chainId: 943,
  rpcUrl: "",
  contractAddress: ZERO_ADDRESS,
  variant: "native",
  nativeSymbol: "NATIVE",
  assetSymbol: "NATIVE",
  assetDecimals: 18,
  protocolName: "",
};

let config = defaultConfig;
let chain: Chain | undefined;
let publicClient: PublicClient | undefined;
let walletClient: WalletClient | undefined;
let account: Address | undefined;
let assetAddress: Address = ZERO_ADDRESS;
let currentCredit = 0n;
let computedClaimPackage: ClaimPackage | undefined;
let preparedAttestation: unknown;
let deploymentChoices: DeploymentChoice[] = [];
let selectedExpectation: DeploymentChoice["expected"] | undefined;
let deploymentChoiceSource: "bundled" | "imported" = "bundled";
let selectedTrust: "bundled" | "imported" | "manual" = "manual";
let noticeTimer: number | undefined;
let verifiedDraftFingerprint: string | undefined;
let verifierFeeEdited = false;
let quoteSequence = 0;

interface VerifiedTarget {
  config: AppConfig;
  chain: Chain;
  publicClient: PublicClient;
  assetAddress: Address;
  runtimeCodeHash: Hex;
  deploymentId: Hex;
  verifierSetHash: Hex;
  devCo: Address;
  securityReserve: Address;
  verifiers: readonly [Address, Address, Address];
  anchorBlockNumber: bigint;
  anchorBlockHash: Hex;
  anchorKind: "finalized" | "safe" | "latest";
  assetRuntimeCodeHash?: Hex;
  trust: "bundled" | "imported" | "manual";
}

let activeTarget: VerifiedTarget | undefined;

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`Missing element #${id}`);
  return found as T;
}

function input(id: string): HTMLInputElement {
  return element<HTMLInputElement>(id);
}

function select(id: string): HTMLSelectElement {
  return element<HTMLSelectElement>(id);
}

function setText(id: string, value: string): void {
  element(id).textContent = value;
}

function showNotice(message: string, kind: "info" | "success" | "error" = "info", sticky = false): void {
  const notice = element("notice");
  notice.textContent = message;
  notice.className = `notice visible ${kind}`;
  if (noticeTimer !== undefined) window.clearTimeout(noticeTimer);
  if (!sticky) {
    noticeTimer = window.setTimeout(() => {
      notice.className = "notice";
    }, 8_000);
  }
}

function errorMessage(error: unknown): string {
  let message: string;
  if (typeof error === "object" && error !== null) {
    const candidate = error as { shortMessage?: unknown; message?: unknown; details?: unknown };
    if (typeof candidate.shortMessage === "string") message = candidate.shortMessage;
    else if (typeof candidate.details === "string") message = candidate.details;
    else if (typeof candidate.message === "string") message = candidate.message.split("\n")[0] ?? candidate.message;
    else message = String(error);
  } else {
    message = String(error);
  }
  return config.rpcUrl ? message.replaceAll(config.rpcUrl, "[configured RPC]") : message;
}

async function withAction(label: string, task: () => Promise<void>): Promise<void> {
  showNotice(`${label}…`, "info", true);
  try {
    await task();
  } catch (error) {
    showNotice(errorMessage(error), "error", true);
  }
}

function draftFingerprint(): string {
  const ids = [
    "network-name",
    "chain-id",
    "rpc-url",
    "contract-address",
    "variant",
    "native-symbol",
    "native-decimals",
    "deployment-choice",
  ];
  return JSON.stringify({
    fields: ids.map((id) => {
      const control = element<HTMLInputElement | HTMLSelectElement>(id);
      return [id, control.value];
    }),
    expected: selectedExpectation ?? null,
    trust: selectedTrust,
  });
}

function setWriteControlsEnabled(enabled: boolean): void {
  document.querySelectorAll<HTMLInputElement | HTMLButtonElement | HTMLSelectElement>(
    ".write-panel input, .write-panel button, .write-panel select",
  ).forEach((control) => {
    control.disabled = !enabled;
  });
  if (enabled) {
    element<HTMLButtonElement>("download-claim-package").disabled = computedClaimPackage === undefined;
    element<HTMLButtonElement>("download-attestation").disabled = preparedAttestation === undefined;
  }
}

function invalidateVerification(message = "Draft changed · verify again"): void {
  activeTarget = undefined;
  verifiedDraftFingerprint = undefined;
  publicClient = undefined;
  chain = undefined;
  walletClient = undefined;
  account = undefined;
  currentCredit = 0n;
  computedClaimPackage = undefined;
  preparedAttestation = undefined;
  input("untrusted-ack").checked = false;
  element("untrusted-ack-box").classList.add("hidden");
  setWriteControlsEnabled(false);
  element("workspace").classList.add("hidden");
  element("deployment-details").replaceChildren();
  setText("deployment-state", message);
  element("deployment-state").className = "pill muted";
  updateWalletDisplay();
}

function requireActiveTarget(): VerifiedTarget {
  if (!activeTarget || !verifiedDraftFingerprint || draftFingerprint() !== verifiedDraftFingerprint) {
    invalidateVerification();
    throw new Error("The deployment draft is not the currently verified target. Verify it again.");
  }
  return activeTarget;
}

function requireClient(): PublicClient {
  return requireActiveTarget().publicClient;
}

function injectedProvider(): EIP1193Provider {
  if (!window.ethereum) throw new Error("No injected EVM wallet was found in this browser.");
  return window.ethereum as EIP1193Provider;
}

function buildChain(next: AppConfig): Chain {
  const rpc = next.rpcUrl || "http://127.0.0.1";
  return defineChain({
    id: next.chainId,
    name: next.networkName,
    nativeCurrency: {
      name: `${next.nativeSymbol} native currency`,
      symbol: next.nativeSymbol,
      decimals: next.variant === "native" ? next.assetDecimals : 18,
    },
    rpcUrls: { default: { http: [rpc] } },
  });
}

async function selectVerificationAnchor(client: PublicClient): Promise<{
  number: bigint;
  hash: Hex;
  kind: "finalized" | "safe" | "latest";
}> {
  for (const kind of ["finalized", "safe", "latest"] as const) {
    try {
      const block = await client.getBlock({ blockTag: kind });
      if (block.hash) return { number: block.number, hash: block.hash, kind };
    } catch {
      // Try the next standardized tag. Some EVM providers implement only latest.
    }
  }
  throw new Error("Provider did not return a usable block anchor.");
}

function readConfigForm(): AppConfig {
  const chainId = Number(input("chain-id").value.trim());
  const assetDecimals = Number(input("native-decimals").value.trim());
  if (!Number.isSafeInteger(chainId) || chainId <= 0) throw new Error("Chain ID must be a positive safe integer.");
  if (!Number.isInteger(assetDecimals) || assetDecimals < 0 || assetDecimals > 255) {
    throw new Error("Native decimals must be an integer from 0 through 255.");
  }
  const rpcUrl = input("rpc-url").value.trim();
  if (rpcUrl) {
    const parsed = new URL(rpcUrl);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new Error("RPC URL must use HTTP or HTTPS.");
  } else if (!window.ethereum) {
    throw new Error("Enter an RPC URL because no injected wallet provider is available for reads.");
  }
  const variant = select("variant").value;
  if (variant !== "native" && variant !== "erc20") throw new Error("Invalid settlement variant.");
  if (variant === "native" && assetDecimals !== 18) {
    throw new Error("This EVM client supports only the standard 18-decimal native-currency convention. Use raw contract tooling for an exotic denomination.");
  }
  const nativeSymbol = input("native-symbol").value.trim().toUpperCase();
  if (!/^[A-Z0-9._-]{1,12}$/.test(nativeSymbol)) throw new Error("Native symbol must be 1–12 simple characters.");
  return {
    networkName: input("network-name").value.trim() || `Chain ${chainId}`,
    chainId,
    rpcUrl,
    contractAddress: requireAddress(input("contract-address").value.trim(), "Escrow contract"),
    variant,
    nativeSymbol,
    assetSymbol: nativeSymbol,
    assetDecimals,
    protocolName: config.protocolName,
  };
}

async function verifyDeployment(): Promise<void> {
  let next = readConfigForm();
  const choiceValue = select("deployment-choice").value;
  if (selectedExpectation && choiceValue) {
    const selected = deploymentChoices[Number(choiceValue)];
    if (
      !selected || selected.config.chainId !== next.chainId
        || selected.config.contractAddress.toLowerCase() !== next.contractAddress.toLowerCase()
        || selected.config.variant !== next.variant
    ) {
      throw new Error("Manual fields no longer match the selected deployment manifest. Choose Manual configuration or restore its values.");
    }
  }
  const nextChain = buildChain(next);
  const provider = next.rpcUrl ? http(next.rpcUrl, { timeout: 15_000, retryCount: 1 }) : custom(injectedProvider());
  const nextClient = createPublicClient({ chain: nextChain, transport: provider, ccipRead: false }) as PublicClient;
  const connectedChainId = await nextClient.getChainId();
  if (connectedChainId !== next.chainId) {
    throw new Error(`RPC/provider reports chain ${connectedChainId}, not configured chain ${next.chainId}.`);
  }
  const bytecode = await nextClient.getBytecode({ address: next.contractAddress });
  if (!bytecode || bytecode === "0x") throw new Error("No contract bytecode exists at that address on this chain.");

  const [onchainAsset, domain, solvent, deploymentId, verifierSetHash, devCo, securityReserve, verifiers] = await Promise.all([
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "asset" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "eip712Domain" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "isSolvent" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "deploymentId" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "verifierSetHash" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "devCo" }),
    nextClient.readContract({ address: next.contractAddress, abi: escrowAbi, functionName: "securityReserve" }),
    Promise.all([0n, 1n, 2n].map((index) => nextClient.readContract({
      address: next.contractAddress,
      abi: escrowAbi,
      functionName: "verifierAt",
      args: [index],
    }))),
  ]);
  const [domainFields, domainName, domainVersion, domainChainId, domainContract] = domain;
  void domainFields;
  if (domainVersion !== "1" || Number(domainChainId) !== next.chainId || getAddress(domainContract) !== next.contractAddress) {
    throw new Error("The contract's EIP-712 domain does not match protocol version 1, this chain, and this address.");
  }
  const actualVariant = onchainAsset === ZERO_ADDRESS ? "native" : "erc20";
  if (actualVariant !== next.variant) {
    throw new Error(`Contract reports the ${actualVariant} variant, but the form selected ${next.variant}.`);
  }

  assetAddress = getAddress(onchainAsset);
  next = copyConfig(next, { protocolName: domainName });
  let assetRuntimeCodeHash: Hex | undefined;
  if (actualVariant === "erc20") {
    const [symbol, decimals, tokenBytecode] = await Promise.all([
      nextClient.readContract({ address: assetAddress, abi: erc20Abi, functionName: "symbol" }),
      nextClient.readContract({ address: assetAddress, abi: erc20Abi, functionName: "decimals" }),
      nextClient.getBytecode({ address: assetAddress }),
    ]);
    if (!tokenBytecode) throw new Error("ERC-20 asset address has no runtime bytecode.");
    assetRuntimeCodeHash = keccak256(tokenBytecode);
    next = copyConfig(next, { assetSymbol: symbol, assetDecimals: decimals });
  }

  const runtimeCodeHash = keccak256(bytecode);
  let matchedManifestFields = 0;
  const compareExpected = (expected: string | undefined, actual: string, label: string): void => {
    if (expected === undefined) return;
    if (expected.toLowerCase() !== actual.toLowerCase()) {
      throw new Error(`${label} does not match the selected deployment manifest.`);
    }
    matchedManifestFields += 1;
  };
  if (selectedExpectation) {
    compareExpected(selectedExpectation.runtimeCodeHash, runtimeCodeHash, "Runtime code hash");
    compareExpected(selectedExpectation.asset, assetAddress, "Asset");
    compareExpected(selectedExpectation.deploymentId, deploymentId, "Deployment ID");
    compareExpected(selectedExpectation.verifierSetHash, verifierSetHash, "Verifier set hash");
    compareExpected(selectedExpectation.devCo, devCo, "Developer recipient");
    compareExpected(selectedExpectation.securityReserve, securityReserve, "Security reserve");
    compareExpected(selectedExpectation.protocolName, domainName, "EIP-712 protocol name");
    if (selectedExpectation.verifiers) {
      if (selectedExpectation.verifiers.length !== 3) throw new Error("Selected manifest must contain exactly three verifiers.");
      selectedExpectation.verifiers.forEach((expected, index) => {
        compareExpected(expected, verifiers[index]!, `Verifier ${index}`);
      });
    }
  }

  const anchor = await selectVerificationAnchor(nextClient);
  const bundledManifestIsComplete = Boolean(
    actualVariant === "native"
      &&
    selectedExpectation?.runtimeCodeHash
      && selectedExpectation.asset
      && selectedExpectation.deploymentId
      && selectedExpectation.verifierSetHash
      && selectedExpectation.devCo
      && selectedExpectation.securityReserve
      && selectedExpectation.protocolName
      && selectedExpectation.verifiers?.length === 3,
  );
  const effectiveTrust = selectedTrust === "bundled" && bundledManifestIsComplete ? "bundled" : selectedTrust === "imported" ? "imported" : "manual";
  const financialTargetChanged = config.chainId !== next.chainId
    || config.contractAddress.toLowerCase() !== next.contractAddress.toLowerCase()
    || config.variant !== next.variant
    || config.assetSymbol !== next.assetSymbol
    || config.assetDecimals !== next.assetDecimals;
  if (financialTargetChanged) {
    input("create-reward").value = "";
    input("create-verifier-fee").value = "";
    verifierFeeEdited = false;
  }
  config = next;
  chain = nextChain;
  publicClient = nextClient;
  activeTarget = {
    config: next,
    chain: nextChain,
    publicClient: nextClient,
    assetAddress,
    runtimeCodeHash,
    deploymentId,
    verifierSetHash,
    devCo: getAddress(devCo),
    securityReserve: getAddress(securityReserve),
    verifiers: [getAddress(verifiers[0]!), getAddress(verifiers[1]!), getAddress(verifiers[2]!)],
    anchorBlockNumber: anchor.number,
    anchorBlockHash: anchor.hash,
    anchorKind: anchor.kind,
    assetRuntimeCodeHash,
    trust: effectiveTrust,
  };
  verifiedDraftFingerprint = draftFingerprint();
  walletClient = undefined;
  account = undefined;
  currentCredit = 0n;
  computedClaimPackage = undefined;
  preparedAttestation = undefined;

  element("workspace").classList.remove("hidden");
  const trustedReleaseTarget = effectiveTrust === "bundled";
  input("untrusted-ack").checked = false;
  element("untrusted-ack-box").classList.toggle("hidden", trustedReleaseTarget);
  setWriteControlsEnabled(trustedReleaseTarget);
  element("erc20-approval").classList.toggle("hidden", config.variant !== "erc20");
  setText(
    "deployment-state",
    trustedReleaseTarget
      ? `Matches release-bundled manifest (${matchedManifestFields} fields)`
      : effectiveTrust === "imported"
        ? `User-imported manifest match (${matchedManifestFields} fields) · provenance untrusted`
        : "Manual live target · provenance untrusted",
  );
  element("deployment-state").className = trustedReleaseTarget ? "pill good" : "pill refundable";
  setText("metric-solvent", solvent ? "Yes" : "NO — DO NOT FUND");
  element("metric-solvent").className = solvent ? "good-text" : "danger-text";
  setText("metric-asset", `${config.assetSymbol} · ${config.variant}`);
  setText("reward-symbol", config.assetSymbol);
  setText("verifier-symbol", config.assetSymbol);
  setText("withdraw-symbol", config.assetSymbol);
  element("deployment-details").innerHTML = `
    <div><span>Chain</span><code>${config.chainId}</code></div>
    <div><span>Contract</span><code>${config.contractAddress}</code></div>
    <div><span>Asset</span><code>${assetAddress}</code></div>
    <div><span>EIP-712 name</span><code>${escapeHtml(config.protocolName)}</code></div>
    <div><span>Runtime code hash</span><code>${runtimeCodeHash}</code></div>
    <div><span>Chain anchor (${anchor.kind})</span><code>${anchor.number} · ${anchor.hash}</code></div>
    ${assetRuntimeCodeHash ? `<div><span>Asset runtime code hash</span><code>${assetRuntimeCodeHash}</code></div>` : ""}
    <div><span>Developer recipient</span><code>${devCo}</code></div>
    <div><span>Security reserve</span><code>${securityReserve}</code></div>
    <div><span>Verifiers 0 / 1 / 2</span><code>${verifiers.join(" · ")}</code></div>
  `;
  updateWalletDisplay();
  await Promise.all([refreshBounties(), refreshFundingQuote()]);
  showNotice(
    trustedReleaseTarget
      ? "Live target matches the complete manifest bundled into this release. Authenticate the app CID/release itself before funding."
      : "Live reads succeeded, but provenance is untrusted. Wallet writes remain disabled until the explicit independent-verification acknowledgement.",
    trustedReleaseTarget ? "success" : "info",
    !trustedReleaseTarget,
  );
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => {
    const entities: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" };
    return entities[character] ?? character;
  });
}

async function requestWallet(switchIfNeeded = false): Promise<{ client: WalletClient; account: Address }> {
  const target = requireActiveTarget();
  const provider = injectedProvider();
  const accounts = (await provider.request({ method: "eth_requestAccounts" })) as string[];
  const selected = accounts[0];
  if (!selected) throw new Error("The wallet did not expose an account.");
  const walletChainHex = (await provider.request({ method: "eth_chainId" })) as string;
  if (Number(BigInt(walletChainHex)) !== target.config.chainId) {
    if (!switchIfNeeded) throw new Error(`Wallet is on chain ${Number(BigInt(walletChainHex))}; switch to chain ${target.config.chainId}.`);
    await switchWalletChain(provider);
  }
  const nextWallet = createWalletClient({ account: getAddress(selected), chain: target.chain, transport: custom(provider) }) as WalletClient;
  account = getAddress(selected);
  walletClient = nextWallet;
  updateWalletDisplay();
  await refreshAccountState();
  return { client: nextWallet, account };
}

async function switchWalletChain(provider = injectedProvider()): Promise<void> {
  const target = requireActiveTarget();
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: toHex(target.config.chainId) }] });
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? Number((error as { code: unknown }).code) : 0;
    if (code !== 4902 || !target.config.rpcUrl) throw error;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId: toHex(target.config.chainId),
        chainName: target.config.networkName,
        nativeCurrency: { name: target.config.nativeSymbol, symbol: target.config.nativeSymbol, decimals: 18 },
        rpcUrls: [target.config.rpcUrl],
      }],
    });
  }
  walletClient = undefined;
  showNotice(`Wallet switched to chain ${target.config.chainId}.`, "success");
}

async function assertClientMatchesTarget(client: PublicClient, target: VerifiedTarget): Promise<void> {
  const chainId = await client.getChainId();
  if (chainId !== target.config.chainId) throw new Error("Injected wallet provider is on the wrong chain.");
  const bytecode = await client.getBytecode({ address: target.config.contractAddress });
  if (!bytecode || keccak256(bytecode) !== target.runtimeCodeHash) {
    throw new Error("Injected wallet provider returned different escrow bytecode than the verified target.");
  }
  const anchor = await client.getBlock({ blockNumber: target.anchorBlockNumber });
  if (!anchor.hash || anchor.hash.toLowerCase() !== target.anchorBlockHash.toLowerCase()) {
    throw new Error("Injected wallet provider is not on the verified chain history anchor.");
  }
  if (target.assetRuntimeCodeHash) {
    const [assetBytecode, symbol, decimals] = await Promise.all([
      client.getBytecode({ address: target.assetAddress }),
      client.readContract({ address: target.assetAddress, abi: erc20Abi, functionName: "symbol" }),
      client.readContract({ address: target.assetAddress, abi: erc20Abi, functionName: "decimals" }),
    ]);
    if (!assetBytecode || keccak256(assetBytecode) !== target.assetRuntimeCodeHash) {
      throw new Error("Injected wallet provider returned different ERC-20 runtime bytecode than the verified target.");
    }
    if (symbol !== target.config.assetSymbol || decimals !== target.config.assetDecimals) {
      throw new Error("Injected wallet provider returned different ERC-20 symbol/decimals than the verified target.");
    }
  }
  const [reportedAsset, deploymentId, verifierSetHash, devCo, securityReserve, verifiers, domain] = await Promise.all([
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "asset" }),
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "deploymentId" }),
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "verifierSetHash" }),
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "devCo" }),
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "securityReserve" }),
    Promise.all([0n, 1n, 2n].map((index) => client.readContract({
      address: target.config.contractAddress,
      abi: escrowAbi,
      functionName: "verifierAt",
      args: [index],
    }))),
    client.readContract({ address: target.config.contractAddress, abi: escrowAbi, functionName: "eip712Domain" }),
  ]);
  const [, domainName, domainVersion, domainChainId, domainContract] = domain;
  const exact = (left: string, right: string): boolean => left.toLowerCase() === right.toLowerCase();
  if (
    !exact(reportedAsset, target.assetAddress)
      || !exact(deploymentId, target.deploymentId)
      || !exact(verifierSetHash, target.verifierSetHash)
      || !exact(devCo, target.devCo)
      || !exact(securityReserve, target.securityReserve)
      || verifiers.some((verifier, index) => !exact(verifier, target.verifiers[index]!))
      || domainName !== target.config.protocolName
      || domainVersion !== "1"
      || Number(domainChainId) !== target.config.chainId
      || !exact(domainContract, target.config.contractAddress)
  ) {
    throw new Error("Injected wallet provider's escrow configuration differs from the verified target.");
  }
}

async function requestWriteContext(): Promise<{ client: PublicClient; wallet: WalletClient; account: Address; target: VerifiedTarget }> {
  const target = requireActiveTarget();
  if (target.trust !== "bundled" && !input("untrusted-ack").checked) {
    throw new Error("Wallet writes are locked until you explicitly acknowledge independent verification of this untrusted target.");
  }
  const connected = await requestWallet(true);
  const provider = injectedProvider();
  const client = createPublicClient({ chain: target.chain, transport: custom(provider), ccipRead: false }) as PublicClient;
  await assertClientMatchesTarget(client, target);
  const walletAccounts = (await provider.request({ method: "eth_accounts" })) as string[];
  if (!walletAccounts[0] || getAddress(walletAccounts[0]) !== connected.account) {
    throw new Error("Injected wallet account changed during target verification.");
  }
  return { client, wallet: connected.client, account: connected.account, target };
}

function updateWalletDisplay(): void {
  if (!account) {
    setText("wallet-state", "Wallet not connected");
    setText("metric-credit", "Connect wallet");
    return;
  }
  setText("wallet-state", `${shortHex(account)} · chain ${config.chainId}`);
  if (!input("refund-recipient").value) input("refund-recipient").value = account;
  if (!input("withdraw-destination").value) input("withdraw-destination").value = account;
  if (!input("claim-solver").value) input("claim-solver").value = account;
}

async function refreshAccountState(): Promise<void> {
  if (!account || !publicClient) return;
  currentCredit = await publicClient.readContract({
    address: config.contractAddress,
    abi: escrowAbi,
    functionName: "claimable",
    args: [account],
  });
  const formatted = `${formatUnits(currentCredit, config.assetDecimals)} ${config.assetSymbol}`;
  setText("metric-credit", formatted);
  setText("withdraw-available", `Available credit: ${formatted}`);
}

async function sendAndConfirm(client: PublicClient, hash: Hex, label: string): Promise<void> {
  showNotice(`${label} submitted: ${hash}. Waiting for chain inclusion…`, "info", true);
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 180_000 });
  if (receipt.status !== "success") throw new Error(`${label} reverted in block ${receipt.blockNumber}.`);
  let finality = "included; provider did not expose finalized state";
  try {
    const finalized = await client.getBlock({ blockTag: "finalized" });
    finality = finalized.number >= receipt.blockNumber ? "finalized" : `included; finalized head is ${finalized.number}`;
  } catch {
    // Some EVM RPCs do not implement the standardized finalized block tag.
  }
  showNotice(`${label} included in block ${receipt.blockNumber} (${finality}).`, "success");
}

function bountyFromUnknown(value: unknown): BountyView {
  return value as BountyView;
}

async function readBounty(id: bigint, client = requireClient(), blockNumber?: bigint): Promise<BountyView> {
  return bountyFromUnknown(await client.readContract({
    address: config.contractAddress,
    abi: escrowAbi,
    functionName: "getBounty",
    args: [id],
    blockNumber,
  }));
}

async function refreshBounties(): Promise<void> {
  const client = requireClient();
  const block = await client.getBlock({ blockTag: "latest" });
  const nextId = await client.readContract({
    address: config.contractAddress,
    abi: escrowAbi,
    functionName: "nextBountyId",
    blockNumber: block.number,
  });
  const latest = nextId - 1n;
  setText("metric-latest", latest.toString());
  const ids: bigint[] = [];
  for (let id = latest; id > 0n && ids.length < 12; id -= 1n) ids.push(id);
  if (ids.length === 0) {
    element("bounty-list").innerHTML = `<p class="empty-state">No bounties have been created on this deployment.</p>`;
    return;
  }
  element("bounty-list").innerHTML = `<p class="empty-state">Loading ${ids.length} bounties directly from the contract…</p>`;
  const values = await Promise.all(ids.map(async (id) => ({ id, bounty: await readBounty(id, client, block.number) })));
  renderBounties(values, block.timestamp);
}

function renderBounties(values: Array<{ id: bigint; bounty: BountyView }>, chainTimestamp: bigint): void {
  element("bounty-list").innerHTML = values.map(({ id, bounty }) => {
    const status = explainBountyStatus(bounty.status, bounty.commitDeadline, bounty.claimDeadline, chainTimestamp);
    const statusClass = bounty.status === 2 ? "paid" : bounty.status === 3 ? "refunded" : status.includes("refundable") ? "refundable" : "open";
    return `
      <article class="bounty-card">
        <div class="bounty-title"><h3>Bounty #${id}</h3><span class="pill ${statusClass}">${escapeHtml(status)}</span></div>
        <div class="reward">${escapeHtml(formatUnits(bounty.reward, config.assetDecimals))} <span>${escapeHtml(config.assetSymbol)}</span></div>
        <dl>
          <div><dt>Sponsor</dt><dd title="${bounty.sponsor}">${shortHex(bounty.sponsor)}</dd></div>
          <div><dt>Winner</dt><dd title="${bounty.winner}">${bounty.winner === ZERO_ADDRESS ? "—" : shortHex(bounty.winner)}</dd></div>
          <div><dt>Commit closes</dt><dd>${escapeHtml(formatTimestamp(bounty.commitDeadline))}</dd></div>
          <div><dt>Claim closes</dt><dd>${escapeHtml(formatTimestamp(bounty.claimDeadline))}</dd></div>
        </dl>
        <details class="hash-details"><summary>Frozen hashes and funding</summary>
          <div><span>Profile</span><code>${bounty.profileId}</code></div>
          <div><span>Specification</span><code>${bounty.specificationHash}</code></div>
          <div><span>Terms</span><code>${bounty.termsHash}</code></div>
          <div><span>Result</span><code>${bounty.resultDigest}</code></div>
          <div><span>Verifier pool</span><code>${formatUnits(bounty.verifierFee, config.assetDecimals)} ${escapeHtml(config.assetSymbol)} · ${formatUnits(bounty.verifierFee / 2n, config.assetDecimals)} per signer${bounty.verifierFee % 2n === 1n ? " · one smallest unit to reserve" : ""}</code></div>
          <div><span>Funded</span><code>${formatUnits(bounty.fundedAmount, config.assetDecimals)} ${escapeHtml(config.assetSymbol)}</code></div>
          <div><span>Refund recipient</span><code>${bounty.refundRecipient}</code></div>
        </details>
        <div class="button-row compact">
          ${bounty.status === 1 && chainTimestamp < bounty.commitDeadline ? `<button class="secondary" type="button" data-commit-id="${id}">Commit</button>` : ""}
          ${bounty.status === 1 && chainTimestamp >= bounty.commitDeadline && chainTimestamp < bounty.claimDeadline ? `<button class="secondary" type="button" data-claim-id="${id}">Claim</button>` : ""}
          ${bounty.status === 1 && chainTimestamp >= bounty.claimDeadline ? `<button class="secondary" type="button" data-refund-id="${id}">Refund</button>` : ""}
        </div>
      </article>
    `;
  }).join("");
}

async function lookupBounty(): Promise<void> {
  const id = requirePositiveInteger(input("lookup-id").value.trim(), "Bounty ID");
  const client = requireClient();
  const block = await client.getBlock({ blockTag: "latest" });
  const bounty = await readBounty(id, client, block.number);
  if (bounty.status === 0) throw new Error(`Bounty #${id} does not exist.`);
  renderBounties([{ id, bounty }], block.timestamp);
}

function parseReward(): bigint {
  const value = input("create-reward").value.trim();
  if (!value) throw new Error("Enter an advertised reward.");
  const reward = parseUnits(value, config.assetDecimals);
  if (reward < 2n) throw new Error("Reward must be at least two smallest asset units.");
  return reward;
}

function parseVerifierFee(): bigint {
  const value = input("create-verifier-fee").value.trim();
  if (!value) throw new Error("Enter an absolute verifier pool.");
  const verifierFee = parseUnits(value, config.assetDecimals);
  if (verifierFee <= 0n) throw new Error("Verifier pool must be greater than zero.");
  return verifierFee;
}

async function fundingDetails(client = requireClient(), requestSequence?: number): Promise<{
  reward: bigint;
  verifierFee: bigint;
  minimum: bigint;
  maximum: bigint;
  required: bigint;
  fixedProtocolFees: bigint;
}> {
  const reward = parseReward();
  const [minimum, maximum] = await Promise.all([
    client.readContract({ address: config.contractAddress, abi: escrowAbi, functionName: "minimumVerifierFee", args: [reward] }),
    client.readContract({ address: config.contractAddress, abi: escrowAbi, functionName: "maximumVerifierFee", args: [reward] }),
  ]);
  if (minimum <= 0n || minimum > maximum) throw new Error("Contract returned an invalid verifier-pool range.");
  let verifierFee: bigint;
  if (!verifierFeeEdited || !input("create-verifier-fee").value.trim()) {
    if (requestSequence !== undefined && requestSequence !== quoteSequence) throw new Error("Stale funding quote.");
    verifierFee = suggestedVerifierFee(reward, minimum, maximum);
    input("create-verifier-fee").value = formatUnits(verifierFee, config.assetDecimals);
  } else {
    verifierFee = parseVerifierFee();
  }
  if (verifierFee < minimum || verifierFee > maximum) {
    throw new Error(
      `Verifier pool must be between ${formatUnits(minimum, config.assetDecimals)} and ${formatUnits(maximum, config.assetDecimals)} ${config.assetSymbol}.`,
    );
  }
  const required = await client.readContract({
    address: config.contractAddress,
    abi: escrowAbi,
    functionName: "requiredFunding",
    args: [reward, verifierFee],
  });
  if (required < reward + verifierFee) throw new Error("Contract returned invalid total funding.");
  return { reward, verifierFee, minimum, maximum, required, fixedProtocolFees: required - reward - verifierFee };
}

async function refreshFundingQuote(): Promise<void> {
  const sequence = ++quoteSequence;
  if (!input("create-reward").value.trim() || !publicClient) {
    setText("funding-quote", "Enter a reward to calculate funding.");
    return;
  }
  try {
    const { reward, required, verifierFee, minimum, maximum, fixedProtocolFees } = await fundingDetails(requireClient(), sequence);
    if (sequence !== quoteSequence) return;
    let allowanceText = "";
    if (config.variant === "erc20" && account) {
      const allowance = await publicClient.readContract({
        address: assetAddress,
        abi: erc20Abi,
        functionName: "allowance",
        args: [account, config.contractAddress],
      });
      allowanceText = ` Current allowance: ${formatUnits(allowance, config.assetDecimals)} ${config.assetSymbol}.`;
    }
    setText(
      "funding-quote",
      `Total funding: ${formatUnits(required, config.assetDecimals)} ${config.assetSymbol}. Advertised solver reward: ${formatUnits(reward, config.assetDecimals)}. Sponsor verifier pool: ${formatUnits(verifierFee, config.assetDecimals)} (${formatUnits(verifierFee / 2n, config.assetDecimals)} to each selected signer${verifierFee % 2n === 1n ? "; one smallest unit to reserve" : ""}). Fixed protocol fees: ${formatUnits(fixedProtocolFees, config.assetDecimals)}. Allowed verifier range: ${formatUnits(minimum, config.assetDecimals)}–${formatUnits(maximum, config.assetDecimals)}.${allowanceText}`,
    );
  } catch (error) {
    if (sequence !== quoteSequence) return;
    setText("funding-quote", errorMessage(error));
  }
}

function createRequest(): {
  refundRecipient: Address;
  reward: bigint;
  verifierFee: bigint;
  commitDeadline: bigint;
  claimDeadline: bigint;
  profileId: Hex;
  specificationHash: Hex;
  termsHash: Hex;
} {
  const reward = parseReward();
  const commitDeadline = dateTimeLocalToSeconds(input("commit-deadline").value, "Commit deadline");
  const claimDeadline = dateTimeLocalToSeconds(input("claim-deadline").value, "Claim deadline");
  if (claimDeadline <= commitDeadline) throw new Error("Claim deadline must be after commit deadline.");
  return {
    refundRecipient: requireAddress(input("refund-recipient").value.trim(), "Refund recipient"),
    reward,
    verifierFee: parseVerifierFee(),
    commitDeadline,
    claimDeadline,
    profileId: requireNonzeroBytes32(input("profile-id").value.trim(), "Profile ID"),
    specificationHash: requireNonzeroBytes32(input("specification-hash").value.trim(), "Specification hash"),
    termsHash: requireNonzeroBytes32(input("terms-hash").value.trim(), "Terms hash"),
  };
}

async function setAllowance(amount: bigint): Promise<void> {
  const context = await requestWriteContext();
  if (context.target.config.variant !== "erc20") throw new Error("This deployment settles in native currency and needs no allowance.");
  const approvalAmount = amount === 0n ? 0n : (await fundingDetails(context.client)).required;
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.assetAddress,
    abi: erc20Abi,
    functionName: "approve",
    args: [context.target.config.contractAddress, approvalAmount],
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, approvalAmount === 0n ? "Allowance clear" : "Allowance approval");
  await refreshFundingQuote();
}

async function createBounty(): Promise<void> {
  const request = createRequest();
  const context = await requestWriteContext();
  const [required, minimum, maximum, solvent] = await Promise.all([
    context.client.readContract({
      address: context.target.config.contractAddress,
      abi: escrowAbi,
      functionName: "requiredFunding",
      args: [request.reward, request.verifierFee],
    }),
    context.client.readContract({
      address: context.target.config.contractAddress,
      abi: escrowAbi,
      functionName: "minimumVerifierFee",
      args: [request.reward],
    }),
    context.client.readContract({
      address: context.target.config.contractAddress,
      abi: escrowAbi,
      functionName: "maximumVerifierFee",
      args: [request.reward],
    }),
    context.client.readContract({
      address: context.target.config.contractAddress,
      abi: escrowAbi,
      functionName: "isSolvent",
    }),
  ]);
  if (request.verifierFee < minimum || request.verifierFee > maximum) {
    throw new Error("Verifier pool is outside the contract's current minimum/maximum range.");
  }
  if (!solvent) throw new Error("Escrow is insolvent according to the injected wallet provider. Do not fund it.");
  if (context.target.config.variant === "erc20") {
    const allowance = await context.client.readContract({
      address: context.target.assetAddress,
      abi: erc20Abi,
      functionName: "allowance",
      args: [context.account, context.target.config.contractAddress],
    });
    if (allowance < required) throw new Error("ERC-20 allowance is below the exact funding requirement. Approve it first.");
  }
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "createBounty",
    args: [request],
    value: context.target.config.variant === "native" ? required : 0n,
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, "Bounty creation");
  await Promise.all([refreshBounties(), refreshFundingQuote()]);
}

function commitInputs(): { bountyId: bigint; resultDigest: Hex; salt: Hex } {
  return {
    bountyId: requirePositiveInteger(input("commit-bounty-id").value.trim(), "Bounty ID"),
    resultDigest: requireNonzeroBytes32(input("commit-result-digest").value.trim(), "Result digest"),
    salt: requireNonzeroBytes32(input("commit-salt").value.trim(), "Salt"),
  };
}

async function computeSolverCommitment(): Promise<ClaimPackage> {
  const target = requireActiveTarget();
  const wallet = await requestWallet(false);
  const values = commitInputs();
  const commitment = computeCommitmentLocally(
    target.deploymentId,
    values.bountyId,
    wallet.account,
    values.resultDigest,
    values.salt,
  );
  computedClaimPackage = {
    schemaVersion: 1,
    chainId: config.chainId,
    contractAddress: config.contractAddress,
    bountyId: values.bountyId.toString(),
    solver: wallet.account,
    resultDigest: values.resultDigest,
    salt: values.salt,
    commitment,
  };
  setText("computed-commitment", commitment);
  (element<HTMLButtonElement>("download-claim-package")).disabled = false;
  return computedClaimPackage;
}

async function submitCommitment(): Promise<void> {
  const values = commitInputs();
  const context = await requestWriteContext();
  const commitment = computeCommitmentLocally(
    context.target.deploymentId,
    values.bountyId,
    context.account,
    values.resultDigest,
    values.salt,
  );
  computedClaimPackage = {
    schemaVersion: 1,
    chainId: context.target.config.chainId,
    contractAddress: context.target.config.contractAddress,
    bountyId: values.bountyId.toString(),
    solver: context.account,
    resultDigest: values.resultDigest,
    salt: values.salt,
    commitment,
  };
  setText("computed-commitment", commitment);
  (element<HTMLButtonElement>("download-claim-package")).disabled = false;
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "commit",
    args: [values.bountyId, commitment],
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, "Solver commitment");
}

function claimValues(): { bountyId: bigint; solver: Address; resultDigest: Hex; salt: Hex } {
  return {
    bountyId: requirePositiveInteger(input("claim-bounty-id").value.trim(), "Bounty ID"),
    solver: requireAddress(input("claim-solver").value.trim(), "Solver"),
    resultDigest: requireNonzeroBytes32(input("claim-result-digest").value.trim(), "Result digest"),
    salt: requireNonzeroBytes32(input("claim-salt").value.trim(), "Salt"),
  };
}

async function prepareAttestation(): Promise<unknown> {
  const client = requireClient();
  const target = requireActiveTarget();
  const result = claimValues();
  const { bounty, commitment, block } = await readClaimReadiness(client, target, result);
  const domain = {
    name: target.config.protocolName,
    version: "1",
    chainId: target.config.chainId,
    verifyingContract: target.config.contractAddress,
  } as const;
  const message = {
    deploymentId: target.deploymentId,
    bountyId: result.bountyId,
    solver: result.solver,
    commitment,
    resultDigest: result.resultDigest,
    reward: bounty.reward,
    verifierFee: bounty.verifierFee,
    profileId: bounty.profileId,
    specificationHash: bounty.specificationHash,
    termsHash: bounty.termsHash,
    verifierSetHash: target.verifierSetHash,
    claimDeadline: bounty.claimDeadline,
  } as const;
  const digest = hashTypedData({ domain, types: acceptedResultTypes, primaryType: "AcceptedResult", message });
  preparedAttestation = {
    schemaVersion: 1,
    purpose: "Proof Bounty Escrow verifier attestation request",
    digest,
    domain,
    types: acceptedResultTypes,
    primaryType: "AcceptedResult",
    message,
    claimReveal: {
      scope: "Unsigned reveal material. Verify it recomputes message.commitment and the public stored solver commitment before signing.",
      bountyId: result.bountyId,
      solver: result.solver,
      resultDigest: result.resultDigest,
      salt: result.salt,
      commitment,
      reward: bounty.reward,
      verifierFee: bounty.verifierFee,
    },
    observedBlock: { number: block.number, timestamp: block.timestamp },
    warning: "Sign this exact EIP-712 payload. Do not use personal_sign. Independently replay the frozen evaluator before signing.",
  };
  setText("attestation-digest", digest);
  (element<HTMLButtonElement>("download-attestation")).disabled = false;
  return preparedAttestation;
}

async function readClaimReadiness(
  client: PublicClient,
  target: VerifiedTarget,
  result: { bountyId: bigint; solver: Address; resultDigest: Hex; salt: Hex },
): Promise<{ bounty: BountyView; commitment: Hex; block: { number: bigint; timestamp: bigint } }> {
  const block = await client.getBlock({ blockTag: "latest" });
  const [bounty, storedCommitment] = await Promise.all([
    readBounty(result.bountyId, client, block.number),
    client.readContract({
      address: target.config.contractAddress,
      abi: escrowAbi,
      functionName: "commitments",
      args: [result.bountyId, result.solver],
      blockNumber: block.number,
    }),
  ]);
  const commitment = computeCommitmentLocally(
    target.deploymentId,
    result.bountyId,
    result.solver,
    result.resultDigest,
    result.salt,
  );
  assertAttestationReady(
    bounty.status,
    bounty.commitDeadline,
    bounty.claimDeadline,
    block.timestamp,
    storedCommitment,
    commitment,
  );
  return { bounty, commitment, block: { number: block.number, timestamp: block.timestamp } };
}

async function relayClaim(): Promise<void> {
  const result = claimValues();
  const firstIndex = Number(input("verifier-index-a").value.trim());
  const secondIndex = Number(input("verifier-index-b").value.trim());
  if (![firstIndex, secondIndex].every((value) => Number.isInteger(value) && value >= 0 && value <= 2)) {
    throw new Error("Verifier indices must be integers 0, 1, or 2.");
  }
  const signatures = [
    { verifierIndex: firstIndex, signature: requireSignature(input("signature-a").value.trim(), "Signature A") },
    { verifierIndex: secondIndex, signature: requireSignature(input("signature-b").value.trim(), "Signature B") },
  ].sort((left, right) => left.verifierIndex - right.verifierIndex);
  if (signatures[0]?.verifierIndex === signatures[1]?.verifierIndex) throw new Error("Verifier signatures must have distinct indices.");
  const context = await requestWriteContext();
  await readClaimReadiness(context.client, context.target, result);
  const ordered = [signatures[0]!, signatures[1]!] as const;
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "claim",
    args: [result, ordered],
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, "Claim relay");
  await Promise.all([refreshBounties(), refreshAccountState()]);
}

async function refundBounty(): Promise<void> {
  const bountyId = requirePositiveInteger(input("refund-bounty-id").value.trim(), "Bounty ID");
  const context = await requestWriteContext();
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "refund",
    args: [bountyId],
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, "Bounty refund");
  await Promise.all([refreshBounties(), refreshAccountState()]);
}

async function withdrawCredit(): Promise<void> {
  const destination = requireAddress(input("withdraw-destination").value.trim(), "Withdrawal destination");
  const amount = parseUnits(input("withdraw-amount").value.trim(), config.assetDecimals);
  if (amount <= 0n) throw new Error("Withdrawal amount must be greater than zero.");
  const context = await requestWriteContext();
  const available = await context.client.readContract({
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "claimable",
    args: [context.account],
  });
  if (amount > available) throw new Error("Withdrawal amount exceeds your current claimable credit.");
  const simulation = await context.client.simulateContract({
    account: context.account,
    address: context.target.config.contractAddress,
    abi: escrowAbi,
    functionName: "withdraw",
    args: [destination, amount],
  });
  const hash = await context.wallet.writeContract(simulation.request);
  await sendAndConfirm(context.client, hash, "Withdrawal");
  await refreshAccountState();
}

function installDeploymentChoices(choices: DeploymentChoice[], source: "bundled" | "imported"): void {
  if (activeTarget) invalidateVerification("Manifest list changed · verify again");
  deploymentChoices = choices;
  deploymentChoiceSource = source;
  selectedExpectation = undefined;
  selectedTrust = "manual";
  const menu = select("deployment-choice");
  menu.innerHTML = `<option value="">Manual configuration</option>`;
  choices.forEach((choice, index) => {
    const option = document.createElement("option");
    option.value = String(index);
    option.textContent = choice.label;
    menu.append(option);
  });
}

function chooseDeployment(index: number): void {
  const choice = deploymentChoices[index];
  if (!choice) return;
  if (activeTarget) invalidateVerification("Deployment selection changed · verify again");
  const next = choice.config;
  input("network-name").value = next.networkName ?? `Chain ${next.chainId}`;
  input("chain-id").value = String(next.chainId);
  input("contract-address").value = next.contractAddress;
  select("variant").value = next.variant;
  config = copyConfig(config, { protocolName: next.protocolName ?? "" });
  selectedExpectation = choice.expected;
  selectedTrust = deploymentChoiceSource;
  setText("deployment-state", "Manifest loaded · not verified");
  element("deployment-state").className = "pill muted";
}

async function importManifestFile(file: File): Promise<void> {
  const raw = JSON.parse(await file.text()) as unknown;
  const choices = normalizeManifest(raw);
  installDeploymentChoices(choices, "imported");
  if (choices.length === 1) {
    select("deployment-choice").value = "0";
    chooseDeployment(0);
  }
  showNotice(`Loaded ${choices.length} deployment entr${choices.length === 1 ? "y" : "ies"}. RPC URLs are intentionally not imported.`, "success");
}

async function importClaimPackage(file: File): Promise<void> {
  const parsed = JSON.parse(await file.text()) as Partial<ClaimPackage>;
  if (parsed.schemaVersion !== 1 || parsed.chainId !== config.chainId || parsed.contractAddress?.toLowerCase() !== config.contractAddress.toLowerCase()) {
    throw new Error("Recovery package does not match this chain and escrow deployment.");
  }
  input("claim-bounty-id").value = String(parsed.bountyId ?? "");
  input("claim-solver").value = String(parsed.solver ?? "");
  input("claim-result-digest").value = String(parsed.resultDigest ?? "");
  input("claim-salt").value = String(parsed.salt ?? "");
  await prepareAttestation();
}

function setHashResult(hash: Hex, detail: string): void {
  const target = select("hash-target").value;
  const targetInput = document.getElementById(target);
  if (!(targetInput instanceof HTMLInputElement)) throw new Error("Hash target is unavailable.");
  targetInput.value = hash;
  setText("hash-output", `${hash} · ${detail}`);
  targetInput.dispatchEvent(new Event("input", { bubbles: true }));
}

function initializeDeadlines(): void {
  const now = Math.floor(Date.now() / 1000);
  input("commit-deadline").value = secondsToDateTimeLocal(now + 24 * 60 * 60);
  input("claim-deadline").value = secondsToDateTimeLocal(now + 7 * 24 * 60 * 60);
}

function prefillAction(action: "commit" | "claim" | "refund", bountyId: string): void {
  input(`${action}-bounty-id`).value = bountyId;
  const details = input(`${action}-bounty-id`).closest("details");
  if (details) details.open = true;
  input(`${action}-bounty-id`).focus();
}

function wireEvents(): void {
  const deploymentDraftIds = [
    "network-name",
    "chain-id",
    "rpc-url",
    "contract-address",
    "variant",
    "native-symbol",
    "native-decimals",
  ];
  for (const id of deploymentDraftIds) {
    const control = element<HTMLInputElement | HTMLSelectElement>(id);
    const eventName = control instanceof HTMLSelectElement ? "change" : "input";
    control.addEventListener(eventName, () => {
      if (activeTarget) invalidateVerification();
    });
  }
  element("apply-config").addEventListener("click", () => void withAction("Verifying deployment", verifyDeployment));
  input("untrusted-ack").addEventListener("change", () => {
    const target = requireActiveTarget();
    if (target.trust === "bundled") return;
    const enabled = input("untrusted-ack").checked;
    setWriteControlsEnabled(enabled);
    showNotice(
      enabled ? "Wallet actions enabled for this independently verified target." : "Wallet actions locked for this untrusted target.",
      enabled ? "info" : "error",
    );
  });
  element("connect-wallet").addEventListener("click", () => void withAction("Connecting wallet", async () => {
    await requestWallet(false);
    showNotice(`Connected ${account}.`, "success");
  }));
  element("switch-chain").addEventListener("click", () => void withAction("Switching wallet chain", async () => {
    await switchWalletChain();
    await requestWallet(false);
  }));
  element("refresh-bounties").addEventListener("click", () => void withAction("Refreshing bounties", async () => {
    await refreshBounties();
    showNotice("Bounties refreshed.", "success");
  }));
  element("lookup-bounty").addEventListener("click", () => void withAction("Reading bounty", lookupBounty));
  input("create-reward").addEventListener("input", () => void refreshFundingQuote());
  input("create-verifier-fee").addEventListener("input", () => {
    verifierFeeEdited = true;
    void refreshFundingQuote();
  });
  element("suggest-verifier-fee").addEventListener("click", () => {
    verifierFeeEdited = false;
    void refreshFundingQuote();
  });
  element("approve-funding").addEventListener("click", () => void withAction("Preparing allowance", async () => {
    await setAllowance(1n);
  }));
  element("clear-allowance").addEventListener("click", () => void withAction("Clearing allowance", () => setAllowance(0n)));
  element("create-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void withAction("Creating bounty", createBounty);
  });
  element("generate-salt").addEventListener("click", () => {
    input("commit-salt").value = randomSalt();
    computedClaimPackage = undefined;
    setText("computed-commitment", "Not computed");
    (element<HTMLButtonElement>("download-claim-package")).disabled = true;
  });
  element("compute-commitment").addEventListener("click", () => void withAction("Computing commitment", async () => {
    await computeSolverCommitment();
    showNotice("Commitment computed locally with the deployment's domain separator.", "success");
  }));
  element("download-claim-package").addEventListener("click", () => {
    if (!computedClaimPackage) return;
    downloadJson(`bounty-${computedClaimPackage.bountyId}-solver-recovery.json`, computedClaimPackage);
  });
  element("commit-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void withAction("Submitting commitment", submitCommitment);
  });
  element("prepare-attestation").addEventListener("click", () => void withAction("Preparing verifier payload", async () => {
    await prepareAttestation();
    showNotice("EIP-712 payload computed locally after chain-time and stored-commitment checks.", "success");
  }));
  element("download-attestation").addEventListener("click", () => {
    if (!preparedAttestation) return;
    const id = input("claim-bounty-id").value.trim() || "unknown";
    downloadJson(`bounty-${id}-verifier-request.json`, preparedAttestation);
  });
  element("claim-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void withAction("Relaying claim", relayClaim);
  });
  element("refund-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void withAction("Refunding bounty", refundBounty);
  });
  element("withdraw-max").addEventListener("click", () => {
    input("withdraw-amount").value = formatUnits(currentCredit, config.assetDecimals);
  });
  element("withdraw-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void withAction("Withdrawing credit", withdrawCredit);
  });
  element("manifest-file").addEventListener("change", (event) => {
    if (activeTarget) invalidateVerification("Manifest import changed · verify again");
    const file = (event.currentTarget as HTMLInputElement).files?.[0];
    if (file) void withAction("Importing manifest", () => importManifestFile(file));
  });
  select("deployment-choice").addEventListener("change", (event) => {
    if (activeTarget) invalidateVerification("Deployment selection changed · verify again");
    const value = (event.currentTarget as HTMLSelectElement).value;
    if (value) chooseDeployment(Number(value));
    else {
      selectedExpectation = undefined;
      selectedTrust = "manual";
    }
  });
  element("claim-package-file").addEventListener("change", (event) => {
    const file = (event.currentTarget as HTMLInputElement).files?.[0];
    if (file) void withAction("Importing recovery package", () => importClaimPackage(file));
  });
  element("hash-file").addEventListener("change", (event) => {
    const file = (event.currentTarget as HTMLInputElement).files?.[0];
    if (!file) return;
    void withAction("Hashing local file", async () => {
      const bytes = new Uint8Array(await file.arrayBuffer());
      const hash = hashExactBytes(bytes);
      setHashResult(hash, `${bytes.length} exact bytes from ${file.name}`);
      showNotice("File hashed locally; it was not uploaded.", "success");
    });
  });
  element("hash-text-button").addEventListener("click", () => {
    const value = element<HTMLTextAreaElement>("hash-text").value;
    const hash = hashExactText(value);
    setHashResult(hash, `${new TextEncoder().encode(value).length} UTF-8 bytes`);
  });
  element("bounty-list").addEventListener("click", (event) => {
    const target = event.target;
    if (!(target instanceof HTMLButtonElement)) return;
    if (target.dataset.commitId) prefillAction("commit", target.dataset.commitId);
    if (target.dataset.claimId) prefillAction("claim", target.dataset.claimId);
    if (target.dataset.refundId) prefillAction("refund", target.dataset.refundId);
  });

  const clearComputed = () => {
    computedClaimPackage = undefined;
    setText("computed-commitment", "Not computed");
    (element<HTMLButtonElement>("download-claim-package")).disabled = true;
  };
  input("commit-bounty-id").addEventListener("input", clearComputed);
  input("commit-result-digest").addEventListener("input", clearComputed);
  input("commit-salt").addEventListener("input", clearComputed);

  if (window.ethereum?.on) {
    window.ethereum.on("accountsChanged", (...args: unknown[]) => {
      const accounts = args[0] as string[] | undefined;
      account = accounts?.[0] ? getAddress(accounts[0]) : undefined;
      walletClient = undefined;
      updateWalletDisplay();
      if (account) void refreshAccountState();
    });
    window.ethereum.on("chainChanged", () => {
      walletClient = undefined;
      account = undefined;
      updateWalletDisplay();
      if (!config.rpcUrl) {
        invalidateVerification("Injected provider changed · re-verify");
        showNotice("The injected read provider changed chains. Switch it back and re-verify the deployment before reading or writing.", "info", true);
      } else {
        showNotice("Wallet chain changed. Reads still use your configured RPC; writes will require switching back.", "info", true);
      }
    });
  }
}

async function loadBundledDeployments(): Promise<void> {
  try {
    const response = await fetch("./deployments.json", { cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" });
    if (!response.ok) return;
    const choices = normalizeManifest(await response.json());
    installDeploymentChoices(choices, "bundled");
  } catch (error) {
    void error;
  }
}

initializeDeadlines();
wireEvents();
void loadBundledDeployments();
