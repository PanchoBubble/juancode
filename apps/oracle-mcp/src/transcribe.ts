// Speech-to-text for the Oracle Telegram bridge (juancode-lr5). Telegram voice notes
// and audio files are transcribed LOCALLY via the `whisper` CLI (openai-whisper) — no
// API key, no per-request cost, and the audio never leaves the Mac. This mirrors how
// oracle.ts shells out to local `claude`/`bd` binaries and honours the project's
// faithful-to-the-environment rule (AGENTS.md): we lean on the tools already installed
// on the machine rather than a hosted service.
//
// Flow: Telegram `getFile` → download the bytes from the file API → write to a temp
// file → run `whisper --output_format txt` → read the transcript → clean up. The binary
// and model are overridable via JUANCODE_WHISPER_BIN / JUANCODE_WHISPER_MODEL so a
// launchd-launched sidecar (whose PATH may lack /opt/homebrew/bin) can point at an
// absolute path. Every failure throws with a short message the bridge turns into a
// clear Telegram reply.

import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";

/** How the local whisper CLI is invoked. `bin` defaults to `whisper` (on PATH);
 *  `model` defaults to the cached `large-v3-turbo` weights. */
export interface WhisperConfig {
  bin: string;
  model: string;
}

/** Resolve the whisper config from the environment. A real export always wins; the
 *  defaults match a standard `pip install openai-whisper` on this Mac. */
export function readWhisperConfig(env: NodeJS.ProcessEnv = process.env): WhisperConfig {
  return {
    bin: (env.JUANCODE_WHISPER_BIN ?? "").trim() || "whisper",
    model: (env.JUANCODE_WHISPER_MODEL ?? "").trim() || "large-v3-turbo",
  };
}

/** Whisper writes `<input-basename>.txt` into `--output_dir`. Given the audio path we
 *  saved, this is the transcript file to read back. Exported for unit testing. */
export function transcriptPathFor(audioPath: string, outputDir: string): string {
  const stem = basename(audioPath, extname(audioPath));
  return join(outputDir, `${stem}.txt`);
}

/** The whisper CLI argv for a one-shot transcription. `--fp16 False` avoids the
 *  CPU-only fp16 warning on Macs without CUDA; `--output_format txt` gives us a clean
 *  transcript file (no timestamps). Exported for unit testing. */
export function whisperArgs(cfg: WhisperConfig, audioPath: string, outputDir: string): string[] {
  return [
    audioPath,
    "--model",
    cfg.model,
    "--output_format",
    "txt",
    "--output_dir",
    outputDir,
    "--fp16",
    "False",
  ];
}

const apiBase = (token: string) => `https://api.telegram.org/bot${token}`;

/** Resolve a Telegram `file_id` to its server-side `file_path` via `getFile`. Bot API
 *  downloads only work for files ≤ 20 MB — Telegram returns an error for anything
 *  larger, which surfaces here as a thrown error. */
async function getFilePath(token: string, fileId: string): Promise<string> {
  const res = await fetch(`${apiBase(token)}/getFile?file_id=${encodeURIComponent(fileId)}`);
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`telegram getFile ${res.status}: ${detail.slice(0, 200)}`);
  }
  const data = (await res.json()) as { ok?: boolean; result?: { file_path?: unknown } };
  const filePath = data.result?.file_path;
  if (typeof filePath !== "string" || !filePath) {
    throw new Error("telegram getFile: no file_path in response");
  }
  return filePath;
}

/** Download the raw bytes of a Telegram file (from the `/file/bot<token>/<path>` host). */
async function downloadFile(token: string, filePath: string): Promise<Buffer> {
  const url = `https://api.telegram.org/file/bot${token}/${filePath}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`telegram file download ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

/** Run the whisper CLI over `audioPath`, returning the transcript text. Reads the
 *  `.txt` whisper writes into `outputDir` (falls back to stdout only if the file is
 *  missing). Kills the process after `timeoutMs` so a stuck model load can't wedge the
 *  bridge. */
export async function runWhisper(
  cfg: WhisperConfig,
  audioPath: string,
  outputDir: string,
  timeoutMs = 180_000,
): Promise<string> {
  const { code, stderr } = await new Promise<{ code: number; stderr: string }>((resolve) => {
    const child = spawn(cfg.bin, whisperArgs(cfg, audioPath, outputDir), {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stderr.on("data", (d) => (err += d));
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ code: -1, stderr: `failed to launch whisper (${cfg.bin})` });
    });
    child.on("close", (c) => {
      clearTimeout(timer);
      resolve({ code: c ?? -1, stderr: err });
    });
  });

  if (code !== 0) {
    throw new Error(stderr.trim().split("\n").pop() || `whisper exited ${code}`);
  }
  const transcript = await readFile(transcriptPathFor(audioPath, outputDir), "utf8").catch(
    () => "",
  );
  return transcript.trim();
}

/**
 * Build a transcriber bound to a bot token: `(fileId) => transcript`. Downloads the
 * Telegram file to a fresh temp dir, runs whisper, and always cleans up the temp dir.
 * This is the real {@link TelegramDeps.transcribe} implementation; tests inject a mock.
 */
export function makeTranscriber(
  token: string,
  cfg: WhisperConfig = readWhisperConfig(),
): (fileId: string) => Promise<string> {
  return async (fileId: string) => {
    const filePath = await getFilePath(token, fileId);
    const bytes = await downloadFile(token, filePath);
    const ext = extname(filePath) || ".ogg";
    const dir = await mkdtemp(join(tmpdir(), "oracle-stt-"));
    const audioPath = join(dir, `audio${ext}`);
    try {
      await writeFile(audioPath, bytes);
      return await runWhisper(cfg, audioPath, dir);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  };
}
