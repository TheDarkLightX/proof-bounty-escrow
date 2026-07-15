import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const vite = join(root, "node_modules", ".bin", process.platform === "win32" ? "vite.cmd" : "vite");

function build() {
  rmSync(join(root, "dist"), { recursive: true, force: true });
  execFileSync(vite, ["build"], { cwd: root, stdio: "inherit", env: { ...process.env, TZ: "UTC" } });
}

function files(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const path = join(directory, entry.name);
      return entry.isDirectory() ? files(path) : [path];
    })
    .sort();
}

function digest() {
  const output = join(root, "dist");
  const hash = createHash("sha256");
  for (const file of files(output)) {
    if (!statSync(file).isFile()) continue;
    hash.update(relative(output, file));
    hash.update("\0");
    hash.update(readFileSync(file));
  }
  return hash.digest("hex");
}

build();
const first = digest();
build();
const second = digest();

if (first !== second) {
  throw new Error(`Builds differ: ${first} != ${second}`);
}

console.log(`Reproducible dist sha256: ${second}`);
