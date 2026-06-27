import { useEffect, useRef, useState } from "react";

/**
 * Phone composer affordances for getting an image or audio clip into the running
 * session. Desktop already has drag-drop + paste (see SessionView); on a phone
 * neither exists, so this bar gives explicit tap targets:
 *
 *   - 📷 Photo  — opens the camera (or photo library) via a capture file input.
 *   - 🎤 Record — records a voice clip in-page with MediaRecorder.
 *   - 📎 Attach — picks any existing image/audio file from the device.
 *
 * Every path funnels the resulting File to `onFile`, which uploads it to the
 * local server and types the saved path into the agent's prompt — exactly what a
 * drag-drop does. Works on mobile Safari/Chrome (capture inputs + MediaRecorder).
 */
export function AttachBar({
  onFile,
  disabled,
}: {
  onFile: (file: File) => void;
  disabled?: boolean;
}) {
  const photoRef = useRef<HTMLInputElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const [recording, setRecording] = useState(false);
  const [recError, setRecError] = useState<string | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const streamRef = useRef<MediaStream | null>(null);

  // MediaRecorder + getUserMedia gate: hide the record button where unsupported
  // (older iOS, insecure origin) so we never offer a dead control.
  const canRecord =
    typeof window !== "undefined" &&
    typeof window.MediaRecorder !== "undefined" &&
    !!navigator.mediaDevices?.getUserMedia;

  // Stop the mic + recorder if the bar unmounts mid-recording (session switch).
  useEffect(() => {
    return () => {
      if (recorderRef.current?.state === "recording") recorderRef.current.stop();
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  const pick = (input: HTMLInputElement | null) => {
    if (disabled) return;
    input?.click();
  };

  const onPicked = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) onFile(file);
    e.target.value = ""; // allow re-picking the same file
  };

  const startRecording = async () => {
    if (disabled || recording) return;
    setRecError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;
      const recorder = new MediaRecorder(stream);
      chunksRef.current = [];
      recorder.ondataavailable = (ev) => {
        if (ev.data.size > 0) chunksRef.current.push(ev.data);
      };
      recorder.onstop = () => {
        streamRef.current?.getTracks().forEach((t) => t.stop());
        streamRef.current = null;
        const type = recorder.mimeType || "audio/webm";
        const ext = type.includes("mp4") || type.includes("m4a")
          ? "m4a"
          : type.includes("ogg")
            ? "ogg"
            : "webm";
        const blob = new Blob(chunksRef.current, { type });
        if (blob.size > 0) {
          onFile(new File([blob], `recording-${Date.now()}.${ext}`, { type }));
        }
      };
      recorder.start();
      recorderRef.current = recorder;
      setRecording(true);
    } catch (err) {
      setRecError(err instanceof Error ? err.message : "mic unavailable");
    }
  };

  const stopRecording = () => {
    if (recorderRef.current?.state === "recording") recorderRef.current.stop();
    setRecording(false);
  };

  const btn =
    "flex items-center gap-1.5 rounded-md border border-neutral-700 px-2.5 py-1.5 text-xs text-neutral-300 enabled:hover:border-sky-500 enabled:hover:text-sky-300 disabled:opacity-40";

  return (
    <div className="flex flex-wrap items-center gap-2 border-t border-neutral-800 bg-neutral-900/40 px-3 py-2">
      <button type="button" onClick={() => pick(photoRef.current)} disabled={disabled} className={btn}>
        📷 Photo
      </button>
      {canRecord && (
        <button
          type="button"
          onClick={recording ? stopRecording : () => void startRecording()}
          disabled={disabled}
          className={
            recording
              ? "flex items-center gap-1.5 rounded-md border border-red-500/70 bg-red-500/10 px-2.5 py-1.5 text-xs text-red-300"
              : btn
          }
        >
          {recording ? (
            <>
              <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-red-400" /> Stop
            </>
          ) : (
            "🎤 Record"
          )}
        </button>
      )}
      <button type="button" onClick={() => pick(fileRef.current)} disabled={disabled} className={btn}>
        📎 Attach
      </button>
      {recError && <span className="text-[11px] text-red-400">{recError}</span>}

      {/* Hidden inputs. `capture` opens the camera directly on mobile. */}
      <input
        ref={photoRef}
        type="file"
        accept="image/*"
        capture="environment"
        hidden
        onChange={onPicked}
      />
      <input ref={fileRef} type="file" accept="image/*,audio/*" hidden onChange={onPicked} />
    </div>
  );
}
