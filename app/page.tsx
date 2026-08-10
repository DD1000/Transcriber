"use client";

import { useEffect, useRef, useState } from "react";

type TranscriptChunk = {
  text: string;
  timestamp?: [number, number | null];
};

type TranscriptionResult = {
  text: string;
  chunks?: TranscriptChunk[];
};

type AppState = "idle" | "ready" | "loading" | "transcribing" | "done" | "error";

const MODEL_URL = "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/+esm";
const FFMPEG_CORE_URL = "https://unpkg.com/@ffmpeg/core@0.12.10/dist/esm";
let transcriberPromise: Promise<(audio: Float32Array, options: object) => Promise<TranscriptionResult>> | null = null;
let converterPromise: Promise<{
  writeFile: (name: string, data: Uint8Array) => Promise<void>;
  exec: (args: string[]) => Promise<number>;
  readFile: (name: string) => Promise<Uint8Array>;
  deleteFile: (name: string) => Promise<void>;
  on: (event: string, callback: (event: { progress?: number }) => void) => void;
}> | null = null;

function formatBytes(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatTime(seconds: number) {
  const minutes = Math.floor(seconds / 60);
  const remainder = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${minutes}:${remainder}`;
}

async function prepareAudio(file: Blob) {
  const context = new AudioContext();
  const decoded = await context.decodeAudioData(await file.arrayBuffer());

  if (decoded.sampleRate === 16000 && decoded.numberOfChannels === 1) {
    await context.close();
    return decoded.getChannelData(0).slice();
  }

  const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * 16000), 16000);
  const source = offline.createBufferSource();
  source.buffer = decoded;
  source.connect(offline.destination);
  source.start();
  const rendered = await offline.startRendering();
  await context.close();
  return rendered.getChannelData(0).slice();
}

async function getTranscriber(onProgress: (message: string, progress?: number) => void) {
  if (!transcriberPromise) {
    transcriberPromise = (async () => {
      const transformers = await import(/* @vite-ignore */ MODEL_URL);
      transformers.env.allowLocalModels = false;
      transformers.env.useBrowserCache = true;

      return transformers.pipeline("automatic-speech-recognition", "Xenova/whisper-tiny.en", {
        device: "wasm",
        dtype: "q8",
        progress_callback: (event: { status?: string; progress?: number; file?: string }) => {
          const fileName = event.file ? ` ${event.file.replace(/.*\//, "")}` : "";
          const label = event.status === "progress" ? "Downloading voice model" : "Preparing voice model";
          onProgress(`${label}${fileName}`, event.progress);
        },
      });
    })();
  }

  return transcriberPromise;
}

function needsLocalConversion(file: File) {
  return /\.(amr|3gp|3gpp)$/i.test(file.name) || /audio\/(amr|3gpp)/i.test(file.type);
}

async function getConverter(onProgress: (message: string, progress?: number) => void) {
  if (!converterPromise) {
    converterPromise = (async () => {
      const { FFmpeg } = await import("@ffmpeg/ffmpeg");
      const converter = new FFmpeg();
      converter.on("progress", ({ progress }) => {
        onProgress("Converting AMR audio on your device", Math.min(100, Math.round((progress ?? 0) * 100)));
      });
      onProgress("Preparing a local AMR converter…");
      await converter.load({
        coreURL: `${FFMPEG_CORE_URL}/ffmpeg-core.js`,
        wasmURL: `${FFMPEG_CORE_URL}/ffmpeg-core.wasm`,
      });
      return converter;
    })();
  }

  return converterPromise;
}

async function convertToWav(file: File, onProgress: (message: string, progress?: number) => void) {
  const converter = await getConverter(onProgress);
  const extension = file.name.split(".").pop()?.toLowerCase() || "amr";
  const inputName = `source.${extension}`;
  const outputName = "converted.wav";
  await converter.writeFile(inputName, new Uint8Array(await file.arrayBuffer()));
  const exitCode = await converter.exec(["-i", inputName, "-ac", "1", "-ar", "16000", outputName]);
  if (exitCode !== 0) throw new Error("The AMR conversion could not complete.");
  const wav = await converter.readFile(outputName);
  await Promise.all([converter.deleteFile(inputName), converter.deleteFile(outputName)]);
  return new Blob([wav], { type: "audio/wav" });
}

export default function Home() {
  const inputRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [state, setState] = useState<AppState>("idle");
  const [isDragging, setIsDragging] = useState(false);
  const [status, setStatus] = useState("Drop an audio file to begin.");
  const [progress, setProgress] = useState<number | null>(null);
  const [transcript, setTranscript] = useState<TranscriptionResult | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => () => { if (audioUrl) URL.revokeObjectURL(audioUrl); }, [audioUrl]);

  const chooseFile = (nextFile: File | undefined) => {
    if (!nextFile) return;
    if (!nextFile.type.startsWith("audio/") && !/\.(mp3|wav|m4a|aac|ogg|flac|webm|amr|3gp|3gpp)$/i.test(nextFile.name)) {
      setState("error");
      setStatus("Please choose an audio file such as MP3, WAV, M4A, AMR, OGG, FLAC, or WebM.");
      return;
    }

    setFile(nextFile);
    setAudioUrl(URL.createObjectURL(nextFile));
    setTranscript(null);
    setProgress(null);
    setState("ready");
    setStatus("Ready when you are. Your audio stays in this browser tab.");
  };

  const transcribe = async () => {
    if (!file) return;

    try {
      setState("loading");
      setProgress(null);
      setStatus("Reading your audio file…");
      const audioToRead = needsLocalConversion(file)
        ? await convertToWav(file, (message, percent) => {
            setStatus(message);
            setProgress(typeof percent === "number" ? percent : null);
          })
        : file;
      setStatus("Reading your audio file…");
      setProgress(null);
      const samples = await prepareAudio(audioToRead);
      const model = await getTranscriber((message, percent) => {
        setStatus(message);
        setProgress(typeof percent === "number" ? percent : null);
      });

      setState("transcribing");
      setProgress(null);
      setStatus("Transcribing locally in your browser…");
      const result = await model(samples, { chunk_length_s: 30, stride_length_s: 5, return_timestamps: true });
      setTranscript(result);
      setState("done");
      setStatus("Transcript complete. Nothing was uploaded.");
    } catch (error) {
      console.error(error);
      setState("error");
      setProgress(null);
      setStatus("That file could not be transcribed here. Try a smaller MP3, WAV, or AMR file, then try again.");
    }
  };

  const transcriptText = transcript?.text?.trim() || "";
  const isWorking = state === "loading" || state === "transcribing";

  const copyTranscript = async () => {
    if (!transcriptText) return;
    await navigator.clipboard.writeText(transcriptText);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  };

  const downloadTranscript = () => {
    if (!transcriptText || !file) return;
    const text = `Transcript: ${file.name}\n\n${transcriptText}\n`;
    const blob = new Blob([text], { type: "text/plain" });
    const href = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = href;
    anchor.download = `${file.name.replace(/\.[^/.]+$/, "")}-transcript.txt`;
    anchor.click();
    URL.revokeObjectURL(href);
  };

  return (
    <main className="app-shell">
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />

      <header className="topbar">
        <a className="brand" href="#top" aria-label="EchoScribe home">
          <span className="brand-mark" aria-hidden="true"><i /><i /><i /></span>
          <span>EchoScribe</span>
        </a>
        <span className="privacy-badge"><b>●</b> Private by design</span>
      </header>

      <section className="hero" id="top">
        <div className="eyebrow"><span /> ON-DEVICE TRANSCRIPTION</div>
        <h1>Turn audio into words.<br /><em>Keep it yours.</em></h1>
        <p className="hero-copy">Drop in a recording and transcribe it for free. The model runs in your browser, so your audio never travels to a server.</p>
      </section>

      <section className="workspace" aria-labelledby="workspace-title">
        <div className="workspace-heading">
          <div><p className="section-label">YOUR RECORDING</p><h2 id="workspace-title">Make a clean transcript</h2></div>
          <span className="language-chip">ENGLISH · TINY WHISPER</span>
        </div>

        <div
          className={`dropzone ${isDragging ? "is-dragging" : ""} ${file ? "has-file" : ""}`}
          role="button"
          tabIndex={0}
          aria-label="Choose an audio file to transcribe"
          onClick={() => inputRef.current?.click()}
          onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") inputRef.current?.click(); }}
          onDragEnter={(event) => { event.preventDefault(); setIsDragging(true); }}
          onDragOver={(event) => event.preventDefault()}
          onDragLeave={() => setIsDragging(false)}
          onDrop={(event) => { event.preventDefault(); setIsDragging(false); chooseFile(event.dataTransfer.files[0]); }}
        >
          <input ref={inputRef} className="visually-hidden" type="file" accept="audio/*,.mp3,.wav,.m4a,.aac,.ogg,.flac,.webm,.amr,.3gp,.3gpp" onChange={(event) => chooseFile(event.target.files?.[0])} />
          <div className="sound-orb" aria-hidden="true"><span /><span /><span /><span /><span /></div>
          {file ? (
            <div className="file-details"><p className="file-ready">FILE READY</p><strong>{file.name}</strong><span>{formatBytes(file.size)} · Click or drop to replace</span></div>
          ) : (
            <div className="file-details"><strong>Drop your audio here</strong><span>or click to browse your device</span></div>
          )}
          <span className="formats">MP3 · WAV · M4A · AMR · AAC · OGG · FLAC · WEBM</span>
        </div>

        {audioUrl && <div className="audio-preview"><span className="preview-label">QUICK LISTEN</span><audio controls src={audioUrl}>Your browser does not support audio preview.</audio></div>}

        <div className="action-row">
          <button className="primary-action" onClick={transcribe} disabled={!file || isWorking}>
            {isWorking ? "Working on it…" : transcript ? "Transcribe again" : "Transcribe for free"}<span aria-hidden="true">↗</span>
          </button>
          <p className={`status ${state === "error" ? "status-error" : ""}`} aria-live="polite"><span className={isWorking ? "status-pulse" : ""} />{status}{progress !== null ? ` ${Math.round(progress)}%` : ""}</p>
        </div>
        {isWorking && <div className="progress-line" aria-label="Preparing transcription"><span style={{ width: `${progress ?? 30}%` }} /></div>}
      </section>

      <section className={`transcript-card ${transcript ? "is-complete" : ""}`} aria-labelledby="transcript-title">
        <div className="transcript-heading">
          <div><p className="section-label">TRANSCRIPT</p><h2 id="transcript-title">{transcript ? "Ready to use" : "Your words, soon"}</h2></div>
          {transcript && <div className="transcript-actions"><button onClick={copyTranscript}>{copied ? "Copied" : "Copy"}</button><button onClick={downloadTranscript}>Download .txt</button></div>}
        </div>
        {transcript ? (
          <div className="transcript-content">
            <p>{transcriptText || "No speech was detected in this audio."}</p>
            {transcript.chunks && transcript.chunks.length > 1 && <details><summary>Show time-coded sections</summary><ol>{transcript.chunks.map((chunk, index) => <li key={`${chunk.text}-${index}`}><time>{formatTime(chunk.timestamp?.[0] ?? 0)}</time><span>{chunk.text}</span></li>)}</ol></details>}
          </div>
        ) : (
          <div className="empty-transcript"><span className="empty-line line-long" /><span className="empty-line line-mid" /><span className="empty-line line-short" /><p>Your transcript will appear here. You can copy it or save it as a text file.</p></div>
        )}
      </section>

      <section className="promise-grid" aria-label="How EchoScribe works">
        <article><span>01</span><h3>Choose a file</h3><p>Use a common audio format from your phone, recorder, or computer.</p></article>
        <article><span>02</span><h3>Process locally</h3><p>A small speech model works right in this browser—no sign-up needed.</p></article>
        <article><span>03</span><h3>Take the text</h3><p>Copy your transcript or download a tidy text file when you’re done.</p></article>
      </section>
      <footer>EchoScribe is free to use. Your audio remains on your device.</footer>
    </main>
  );
}
