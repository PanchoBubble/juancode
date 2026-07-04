import { describe, expect, it } from "vitest";
import { readWhisperConfig, transcriptPathFor, whisperArgs } from "./transcribe.ts";

describe("readWhisperConfig", () => {
  it("defaults to the whisper CLI + large-v3-turbo", () => {
    expect(readWhisperConfig({})).toEqual({ bin: "whisper", model: "large-v3-turbo" });
  });

  it("honours env overrides (a real export wins)", () => {
    const cfg = readWhisperConfig({
      JUANCODE_WHISPER_BIN: "/opt/homebrew/bin/whisper",
      JUANCODE_WHISPER_MODEL: "base",
    });
    expect(cfg).toEqual({ bin: "/opt/homebrew/bin/whisper", model: "base" });
  });

  it("ignores blank overrides", () => {
    expect(readWhisperConfig({ JUANCODE_WHISPER_BIN: "  ", JUANCODE_WHISPER_MODEL: "" })).toEqual({
      bin: "whisper",
      model: "large-v3-turbo",
    });
  });
});

describe("transcriptPathFor", () => {
  it("maps the audio file to whisper's <stem>.txt in the output dir", () => {
    expect(transcriptPathFor("/tmp/x/audio.ogg", "/tmp/x")).toBe("/tmp/x/audio.txt");
    expect(transcriptPathFor("/tmp/x/audio.mp3", "/tmp/out")).toBe("/tmp/out/audio.txt");
  });
});

describe("whisperArgs", () => {
  it("requests a clean txt transcript with the configured model", () => {
    const args = whisperArgs({ bin: "whisper", model: "large-v3-turbo" }, "/tmp/a.ogg", "/tmp/out");
    expect(args).toEqual([
      "/tmp/a.ogg",
      "--model",
      "large-v3-turbo",
      "--output_format",
      "txt",
      "--output_dir",
      "/tmp/out",
      "--fp16",
      "False",
    ]);
  });
});
