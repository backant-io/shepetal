# Wispr Flow 1.6.1174: transcription and text pipeline (RE notes)

Scope: how Wispr Flow turns speech into inserted text, what runs in the cloud, and what shepetal must rebuild with local models only.
Method: static reading of the bundled JS and the Swift helper with grep and Python. Nothing was launched and no Wispr server was contacted. REA was not run, because there was not enough time in the sprint and the minified JS could be read directly.
Behavior is paraphrased. No code, prompts or assets are copied.

Evidence key:
- `main` = `/Users/sorcecoder/shepetal-re/asar/.webpack/main/index.js` (Electron main bundle, minified). Symbols are class/static/string names in that file.
- `helper` = `/Applications/Wispr Flow.app/Contents/Resources/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow`.
- Extracted context dumps: `/Users/sorcecoder/shepetal-re/textpipe/ctx1.txt`, `/Users/sorcecoder/shepetal-re/textpipe/ctx2.txt`.

## 1. Features

| Feature | What it does | Where it runs | Evidence (main) |
|---|---|---|---|
| Dictation | Hold a hotkey, speak, and formatted text is pasted into the focused app | Cloud ASR plus cloud LLM | `startGrpcStream`, `sendFlowRequest` |
| Auto-edits / "smart formatting" | Removes fillers, handles backtracking ("scratch that", "actually", "I mean"), punctuation, lists, email formatting | Cloud LLM (pipeline step `format`) | pipeline enum `TRANSCRIBE/ALIGN/FORMAT`; `sendSmartFormattingNotifications` |
| Formatting levels | "Apply AI formatting", "No AI formatting" (raw), "Casual messaging" (only proper nouns are capitalized), "All lowercase" | Choice on the client, applied on the server, all-lowercase applied on the client | enum `$Q` (`Format`, `Raw`, `OnlyCapitalizeProperNouns`, `AllLower`); `pipelineSteps()` |
| Editing strength | VERBATIM / LIGHT / MEDIUM / HEAVY. The default auto-cleanup level is Light. | Server | proto enum in `flow_api.v1.StyleConfig.editing_strength`; prefs `autoCleanup.level` |
| Styles per app category | Writing style for each of work / personal / email / other: FORMAL, CASUAL, VERY_CASUAL, EXCITED, GENZ (GENZ is mapped to VERY_CASUAL). Built-in groups: Work messages = Slack and Teams; Email = Gmail, Outlook and Superhuman; Messages = Messages, WhatsApp, WeChat and Messenger; Others. Custom styles are allowed (`source:"custom"`). | Server LLM, selected by the app type that the client detects | `flow_api.v1.GeneralWritingStyle{other,personal,work,email}`; built-in style table (`"Work messages"`, `stylePreference:"formal"` default); `personalizationStyleSettings` |
| App-type detection | Client sorts the frontmost app or URL into OTHER / BROWSER / PERSONAL_MESSAGING / WORK_MESSAGING / EMAIL / CHATBOT / DEVELOPER | Client | proto `AppType` enum; `getAppType(bundleId,url)`; a large app/URL table (e.g. Netflix, WeChat entries) |
| Slack tagging | If you say "at <name>" and that name is among the words visible on screen, the client turns it into `@name` | Client regex, also server step `slack_tagging` | `SLACK_BUNDLE_IDS`, `SlackTagging` flag, `TaggingStyle.slack` |
| Email signature | Adds an optional "sent with Flow" signature in email apps | Server step `email_signature` | `SignatureStyle{flow_signature_prefix,...}`, `email_signature_added` |
| Command mode | Select text and speak an instruction, through a dedicated hotkey or by starting the dictation with "Hey Flow". "Hey Flow" is not a wake-word model: the client matches the start of the transcript against a short list of spellings (hey flow/flo, hay flow, "ask perplexity"). The router returns one of: edit_text or draft_text (the result is pasted), ask_llm (opens Perplexity), build_app (opens a URL). Pro plan only. | Cloud: `/llm/command_mode_route`, `/llm/command_mode`, `/llm/instruct_mode` | `commandModeRoute(full_text, selected_text, instruction)`; `findMatchingHandler`; prefix list `_t=["hey flow",...]`; notifications `CommandModeUpgradeToPro`, `UseHeyFlowForCommandMode` |
| Instruct mode / auto-routing (newer command mode) | Each utterance can be classified by the server into one of: dictation, instruct, transform, updateSettings, modelIsUnsure. The input is the ASR text plus app, textbox, AX context and session history. The client waits at most 2 s for the classification and otherwise treats the utterance as dictation. Flags: `auto-detect-instruct-mode`, `instruct-models`. Instruct actions include paste, show_in_chat, query_user_local_data and end_session. | Cloud `/llm/classify_intent` | route enum `Dictation="dictation", Instruct, Transform, UpdateSettings, ModelIsUnsure`; `classifyIntent`; the 2e3 race in the route resolver |
| "Press enter" voice command | When a dictation ends with "press enter", the phrase is stripped and the client presses Enter after the paste. It also triggers when the LLM dropped the phrase but the raw ASR text still has it. | Client (regex on the formatted and the raw text) | log tag `[PressEnterCommand]`; prefs `pressEnterCommandEnabled` |
| Voice preferences and settings by voice | Speak a rule ("always be formal", "I don't like em dashes"). An LLM tool call pulls out the rule and an optional scope filter (`key:value` dimensions) and saves it. Tools such as `route_transform` and `resolve_mutations` change settings. | Cloud LLM with tool calls | tool schemas `extract_voice_preference`, `route_transform`, `resolve_mutations`, `classify_category` |
| Realtime voice actions | A realtime voice-agent session with frames `session.start`, `session.update`, `audio.append` (PCM16, 24 kHz), `audio.commit`, `text.input`, `tool.call` and `tool.result`, plus file tools (`read_file`, `grep_file`, `edit_file`). It looks like OpenAI Realtime (the `gpt-realtime-2` enum). | Cloud | `VoiceActionsRealtimeClient`; `.webpack/main/agentToolBridge.js` |
| Transforms | Polish, prompt-engineer, turn-to-list, translate-to-English, empathize, custom transform, romanization | Cloud LLM | task enum `PolishTransform`, `PromptEngineerTransform`, `TurnToListTransform`, `TranslateToEnglishTransform`, `EmpathizeTransform`, `CustomTransform`, `TranscriptRomanization`; `/llm/polish_text` |
| Personal dictionary | Words or phrases. A word can be starred. Personal and team lists. At most 200 entries are sent (`dictionary_context.slice(0, D)`, D=200). A word can carry a replacement, e.g. the default "btw" becomes "by the way". | Sent to the server as ASR/LLM context. Replacements are also applied on the client with a regex. | `D.dictionaryRegex`, `replacementMap`, `StaticVocabulary{dictionary_personal,...,_starred}`, `/api/v1/dictionary/personal|team|shared` |
| Dictionary auto-learn | When you edit pasted text, the client aligns the original and the edited text, keeps the substituted words and adds them to the dictionary. Undo is possible. Skips stopwords and single CJK tokens. | Client (alignment and filters). An `/llm/extract_edited_words` endpoint also exists. | prefs `shouldAutoLearnWords:true`; `addAutoLearnedWords`, `undoAutoLearnedWords`, `parseAlignmentSteps`; flag `DictionaryPhraseLearning`; stopword list loaded from a CDN (`dictionary_stopwords.json`) |
| Dictionary sources and ranking | Sources: MANUAL, USER_EDITS, MEETING_TRANSCRIPT, MEETING_SUMMARY, APP_CONTEXT, BULK_IMPORT, IOS_CONTACTS, DEFAULT. Sorted by recency (less than 1 day, less than 14 days, older), then source priority, then frequency. Starred words go first. The list is truncated before it is sent. | Client | source enum with `MANUAL="manual"`...; the ranking comparator next to `dictionaryRegex`; `dictionary_context:[starred..., team starred..., personal..., team...].slice(0, D)` |
| Snippets | A spoken trigger expands to stored text, rich HTML being optional. If the whole dictation, with punctuation stripped, equals a trigger, the client returns the expansion directly. Otherwise triggers are replaced inline. Personal and team lists. | Client (deterministic). Also sent to the server in `Replacements.snippets_*`. | `dictionaryStrippedSnippetMap`, `personalSnippetMap`, `teamSnippetMap`, `snippetHtmlMap`, flag `RichTextSnippets` |
| Multi-language | The proto enum `flow_api.v1.Language` has 107 values, including regional variants (ENGLISH_US, ENGLISH_UK, ENGLISH_CA, CHINESE_SIMPLIFIED/TRADITIONAL, GERMAN_SWISS, ...) and UNDETERMINED. User picks a set of languages (`selectedLanguages`). The server detects the language and returns `detected_language`. There is a "low confidence" flag and a "check language" user action. Hinglish is called out. | Server | `language: prefs.user.selectedLanguages`, `prev_detected_language`, proto `Transcription.language_detection_low_confidence`, `UserActions.check_language`, events `HinglishNote*`; `/llm/format_non_english` |
| Translation | Dictation: the translate-to-English transform. Meetings/notetaker: live translation with a target language. | Cloud | `liveTranslationTarget`, `translationStreamReplacement`, `TranslateToEnglishTransform` |
| Whisper mode | Detects quiet speech, used in onboarding and the mic quiz | Server ASR or gain handling | `usedWhisperMode`, `OnboardingWhisperIntro` |
| Context awareness | Sends words from the accessibility tree, OCR words (opt-in screen OCR), VS Code variable and file names, textbox before/selected/after text, nearby text, chat conversation and an optional screenshot | Client collects, server uses | `serializeFlowRequest` context; proto `Context{textbox,vocabulary,content_text,content_html,screenshot,conversation}`; `DynamicVocabulary{screen_content_ax,screen_content_ocr,variable_names,file_names}` |
| Voice profile ("MyVoice") | Builds a per-user profile of your writing style for personalization | Cloud | `/llm/voice_profile`, `GenerateVoiceProfile`, flag `MyVoice` |
| "Canto" | Only a launch modal and analytics events in this build (`CantoLaunchModalShown/Clicked`). No model name or route called "canto" was found in `main`. Canto is most likely the server-side model behind `inference.wisprflow.com`. | Cloud | `CantoLaunchModal` |

## 2. Pipeline: audio, then ASR, then post-processing, then insertion

1. **Capture**: 16 kHz mono PCM. The client cuts it into 20 ms packets and keeps a volume value per packet. A chunk has a hard cap of 28 s.
   - Evidence: `main` constants `O=16e3, C=28, I=C*O, z=C/.02`; the packet serializer (`packets`, `volumes`, `packet_duration`, `audio_encoding`, `byte_encoding: binary|ascii85`).
2. **Encode**: Opus is used when it is supported and the `use-opus` / `opus-desktop-experiment` flags are on. Otherwise WAV/PCM16.
   - Evidence: `.webpack/main/opusEncoder.worker.js`, `.webpack/main/incrementalOpusEncoder.worker.js`, `opusscript_native_wasm.wasm` (Opus compiled to WASM, running in a worker); the log text "OPUS encoder unsupported ... will use wav"; proto `AudioEncoding{WAV, OPUS}`. MessagePack is behind the `use-msgpack` flag.
3. **Transport**: the primary path first, then the fallbacks:
   - (a) **Primary: bidirectional gRPC stream** `flow_api.v1.TranscriptionService/TranscribeStream`, which takes client and server streams. A unary `Transcribe` also exists. The host comes from `https://inference-info.wisprflow.com/dictation_url.txt` and must be on an allow-list: `inference.wisprflow.com`, `model-v31pl413.grpc.api.baseten.co`, `wispr-ai-prod--prod-grpc-server-flowgrpcserver.us-east.modal.direct`. The audio is served on Baseten and Modal GPUs.
     - Stream messages: `Request{init, context, payload, commit}`.
     - `Init{metadata, preferences, state}`. `Preferences{user, language, vocabulary(StaticVocabulary), replacements(Replacements incl. snippets), style_config}`.
     - `Payload{audio_packets | audio_file}`. `commit` ends the utterance. There are heartbeats (`Heartbeat{audio_received_seconds, commit_ack}`) and timeouts `COMMIT_HEARTBEAT_TIMEOUT_MS` / `COMMIT_COMPLETION_BACKSTOP_MS`.
     - Server stream: `Response{result, state, all_states, heartbeat}`.
     - `State` carries `progress{transcriber, formatter, ...}`, `raw_text`, `formatted_text`, `candidate_beams`, `audio_snr`, `audio_volume` and `mean_alignment_score`. Partial results stream back while you speak (flag `stream-text`).
   - (b) **Fallback: websocket** `wss://api.wisprflow.ai/` or `wss://api-east.wisprflow.ai/`. Analytics events `grpc_fallback_to_websocket` and `grpc_disabled_temporarily`. A `grpc-http-race` flag races the protocols.
   - (c) **Older/backup paths** in `AriaWebClient`:
     - `transcribeOpenAI` posts base64 audio to `/llm/asr` with a language hint (set only if the user picked exactly one language) and an empty prompt. The finalErrorReason `OpenAINoResponseData` points to OpenAI's ASR behind it.
     - `transcribeOpenAIAudioChunks` does the same for chunked audio (`/llm/asr_audio_chunks`).
     - `transcribeAndFormat` posts to `/llm/api` with audio plus `properties{app_type, language, before_text, after_text, selected_text, dictionary}`. Here `dictionary` is a deduplicated list of at most 200 words, built from AX words, OCR words, the user's first and last name and the dictionary. This is exactly the hotword/prompt-biasing list that shepetal should build.
   - (d) **Fallback: one-shot HTTPS POST** of the whole utterance as JSON or msgpack ("binary") to a Baseten Chain, `https://chain-o232k03l.api.baseten.co/environments/production/run_remote`, with an `Api-Key` header. Behind the `wispr-chain-via-aria-web` flag it goes through `<aria-web>/llm/dictation` instead. There are also HTTP chunk paths `/llm/asr` and `/llm/asr_audio_chunks` (`httpChunksSent`).
     - Evidence: `class C` with `BASE10_PRODUCTION_ENDPOINT`, `serializeFlowRequest`, `sendFlowRequest`, `secondFallbackReason`.
4. **Server ASR**: an ensemble. The proto enum `Origin` lists `MIXTURE, WHISPER, SCRIBE, VOXTRAL, QWEN`. SCRIBE is ElevenLabs Scribe, VOXTRAL is Mistral Voxtral and QWEN is Qwen ASR; these are inferences from the names.
   - Every `CandidateBeam{text, score, confidence, origin, alignment_score, word_alignments[]}` is labeled with its origin. `ResponseTime.external_asr_time` points to third-party ASR calls, and `Metadata.always_wait_scribe` exists.
   - So the server runs several ASR engines and merges them ("MIXTURE"), probably with alignment-based scoring. That would be the `align` pipeline step.
   - A `UseCandidateAsr` flag routes to `wispr-ai--*.modal.direct` candidate models.
5. **Server LLM formatting** (pipeline steps `transcribe, align, format`, plus optionally `lowercase_sentences`, `slack_tagging`, `email_signature`):
   - The LLM rewrites the raw transcript using style, editing strength, dictionary, app context and the previous ASR/LLM text of this session.
   - It returns `asr_text`, `llm_text` / `formatted_text` (HTML), `detected_language`, `average_log_prob`, `starts_with_proper_noun`, `stats{word_deletions, word_substitutions, context_word_count}` and `format_skip_reason`.
   - `external_llm_time` exists, and the client has a model enum: `claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-opus-4-6`, `gpt-oss-120b` (Cerebras), `gpt-realtime-2`, `gpt-5.5`. A provider enum `GROQ / OPENAI` sits on `CompletionRequestError`.
   - The current gRPC path does not name the dictation formatting model on the client. An older direct-call path, still in the bundle, does name it.
     - `AriaWebClient.formatEnglish` posts to `/llm/formatting` with `model_name` set to an OpenPipe fine-tune of **Llama 3.1 8B**: `openpipe:llama3-1-8b-12-09-2024` in general, and an email-specific fine-tune, `openpipe:llama3-1-05-21-data-email`, when the app type is email.
     - Non-English text goes to `/llm/format_non_english` (`formatNonEnglish(app_type, content, detected_language, user_languages)`).
     - So Wispr's formatter has been a **fine-tuned 8B model**, which is good news for local inference. Canto is probably the successor.
6. **Client post-processing**, in order, from the result handler around `findAndReplaceDictionaryWords` in `main`:
   1. All-lowercase mode lowercases the text.
   2. If the whole utterance is a snippet trigger, the expansion is returned.
   3. Otherwise a regex replaces dictionary replacement words and snippet triggers inline.
   4. Capitalization of the first letter follows `starts_with_proper_noun`.
   5. App-specific fixes, e.g. HTML lists are turned into plain bullets for the Front app (`stripLists`).
   6. Slack `@` tagging.
   7. Smart-formatting tips. The tip logic compares raw and formatted text against a fixed list of backtrack cue phrases (scratch that, never mind, forget that, cancel that, strike that, actually, I mean, no wait, wait no). The tip fires when a cue is in the raw text, is missing from the output and `word_deletions` is high enough. Backtracking itself is done by the server LLM, not the client.
7. **Insertion**: the client writes the clipboard and simulates paste (`dictationResultInfo.pasteOutcome*`, `clipboardLengthBefore/After`, `focusedControlChanged`). Rich text goes as HTML when the target supports it.
8. **Learning loop**: after pasting, the client watches edits in the focused field (via AX) and aligns the original against the edited text. Substituted words become `USER_EDITS` dictionary entries (`addAutoLearnedWords`).

Latency data:
- Recorded fields: `basetenNetworkMetrics{totalDurationMsecs, totalNetworkOverheadMsecs, serverProcessingTimeMsecs, llmTimeMsecs, asrTimeMsecs, pastedTimeMsecs, timeToFirstByteMsecs, uploadSpeedMbps}`, `component_times`, `generated_tokens`, proto `ResponseTime{transcribe, format, post_process, total, generate_queue_duration, generate_work_duration}`.
- No target numbers are hardcoded on the client.
- Timeouts that were seen: 15 s for the HTTP fallback request (`bP=15e3`), an 8 s fetch of the dictation URL, an endpoint refresh every 1 h, and a 3 s wait for app readiness.

## 3. Local vs cloud: what is server-side

- **On-device ASR: none.**
  - No `*.mlmodelc`, `*.onnx`, `*.gguf`, `*.tflite` or Whisper files in the app bundle. The only `.bin` is Electron's V8 snapshot.
  - The Swift helper has no SFSpeech, CoreML or Whisper strings.
  - "offline" in `main` refers to meeting recording, which uploads later (`meetingStartedOffline`, `offline_without_local_audio`), not to local dictation.
  - Without network, dictation fails or retries.
- **Server-side**: ASR (ensemble), alignment/merge, language detection, LLM formatting (fillers, backtracking, punctuation, lists, style/tone, editing strength), Slack tagging and signature steps, command mode routing and execution, transforms, translation, voice profile, screen OCR (`extractProperNounsFromScreenCapture` uploads a screen image to `/llm/ocr` to pull out proper nouns; it is opt-in, `shouldOCRScreenCapture:false`), extraction of learned words (`/llm/extract_asr_words`, `/llm/extract_edited_words`), intent classification (`/llm/classify_intent`), formality detection and "sensibility" checks (`/llm/detect_formality`, `/llm/check_sensibility`).
- **Sent to the cloud with every dictation**:
  - audio
  - app name, bundle id and URL
  - words from the accessibility tree and OCR words from the screen
  - IDE variable and file names
  - up to 500 chars of textbox contents, and before/selected/after text
  - nearby text
  - the dictionary (truncated) and replacements/snippets
  - user first/last name and email
  - selected languages and style settings
  - previous ASR/LLM text of the session
  - session and device metadata
  - (`serializeFlowRequest`; proto `Context`, `User`, `Preferences`)
- **Client-side**: capture, Opus encoding (WASM worker), app-type classification, collecting context through AX and OCR, dictionary ranking and truncation, snippet expansion and regex replacement, all-lowercase mode, first-letter capitalization, Slack `@` tagging, per-app list stripping, paste/insertion, alignment for auto-learning, and filtering stopwords and CJK tokens.

## 4. What shepetal must build (local models only)

### Needs an ASR model only
- Basic dictation with punctuation and casing:
  - Whisper large-v3-turbo or distil-whisper, run through whisper.cpp with Metal (Mac), CoreML/ANE (iPhone) or CUDA/Vulkan/CPU (Linux).
  - Or NVIDIA Parakeet-TDT, or Moonshine for low latency on phones.
  - Whisper already produces punctuation and casing.
- Dictionary biasing:
  - Pass the top-N ranked dictionary words in Whisper's `initial_prompt`, keeping it under about 200 tokens and putting starred words first (this mirrors Wispr's order).
  - Or use hotwords or contextual biasing with Parakeet/NeMo or sherpa-onnx hotwords.
  - Also feed visible-screen words, which shepetal can collect through AX on Mac and AT-SPI on Linux, as part of the same prompt. This is Wispr's "dynamic vocabulary".
- Language auto-detect: Whisper's language ID, restricted to the user's selected set. Pick the language with the highest probability among the allowed ones.
- Streaming partial text: VAD (Silero) plus a sliding window, or whisper.cpp stream mode. The final pass runs on the full utterance. Wispr also does a full pass at commit.
- "Whisper mode" (quiet speech): AGC/normalization before the ASR. No model needed.

### Needs a small local text model (Wispr itself used a fine-tuned Llama 3.1 8B; around 1-4B is the target here, e.g. Qwen2.5/3 1.5-3B Instruct, Llama 3.2 3B, Gemma 3 1-4B, through llama.cpp or MLX; on iPhone at most about 1-3B with 4-bit quantization)
- Backtracking and self-corrections ("actually, I mean...", "scratch that"). A rule can delete text after "scratch that", but "Tuesday, actually Wednesday" needs a model.
- Turning speech into lists, paragraphs and email structure.
- Style/tone per app category (formal, casual, very casual, excited) and editing strength (verbatim, light, medium, heavy). Both are prompt parameters to the same model.
- Command mode: rewrite the selected text according to a spoken instruction. Routing between edit, draft and ask can be a short classification prompt or a keyword rule.
- Transforms: polish, turn into a list, make more empathetic, prompt-engineer, custom.
- Translation (dictation translated into English): Whisper's `translate` task covers X to English with the ASR only. Other targets need an LLM or NLLB/Marian.
- Optional: merging candidates from several ASR engines (Wispr's MIXTURE). Skip it for v1, because one good ASR plus an LLM cleanup gets most of the gain.

### Deterministic rules (no model)
- Removing fillers: regex for um, uh, er, ah, hmm, "you know" and "like" (only when surrounded by commas or pauses). Collapse repeated words ("the the"). Run this before the LLM, or alone in "no AI formatting" mode.
- Simple backtrack cues: "scratch that", "cancel that" and "strike that" at a clause boundary delete the previous clause or sentence.
- Snippets: exact match on the normalized whole utterance returns the expansion. Otherwise replace triggers inline with a regex on word boundaries, case-insensitive (this is what Wispr does).
- Dictionary replacements (e.g. "btw" becomes "by the way") and fixing the casing of dictionary terms, as a regex after the ASR.
- All-lowercase mode, "only capitalize proper nouns" mode (lowercase, then restore the casing of dictionary and proper-noun words), and the first-letter capitalization rule.
- Spoken punctuation and commands ("new line", "new paragraph", "period"), if wanted.
- Slack-style `@name` tagging: "at <name>" plus the name appearing in the AX words on screen.
- App-category detection: a table from bundle id or URL to a category (work, personal, email, other, plus browser, chatbot and developer).
- Auto-learn dictionary (Wispr also asks an LLM, `/llm/extract_edited_words`, to accept or reject the candidates; shepetal can do that step with the same small local LLM or skip it):
  - Use word-level alignment (Levenshtein or difflib) between the pasted text and the text after the user's edit, keep the substitutions and drop stopwords.
  - Store each word with its source and last-used time, and rank by recency bucket, then source, then frequency.
  - On Mac and Linux this needs a way to read the text field again after pasting (AX or AT-SPI). On iPhone it only works inside shepetal's own keyboard or editor.

### Per platform
- **Mac**:
  - ASR: whisper.cpp with Metal or CoreML encoder, or MLX Whisper. Parakeet through MLX is also viable.
  - Text model: MLX or llama.cpp 3B.
  - Context: AX tree words.
  - Insertion: clipboard plus Cmd-V.
- **iPhone**:
  - Use a keyboard extension, which is memory-limited (around 50-70 MB, so the model cannot run inside the extension). The containing app runs WhisperKit/CoreML or Moonshine/Parakeet, and the keyboard gets text over an app group.
  - The LLM cleanup must be about 1B or smaller, or use Apple Foundation Models (on-device, iOS 26+) as the local text model.
  - Rules cover the rest.
- **Linux**:
  - ASR: whisper.cpp (CUDA/Vulkan/CPU) or faster-whisper.
  - Text model: llama.cpp.
  - Context: AT-SPI.
  - Insertion: wtype or ydotool on Wayland, xdotool on X11, or clipboard plus a simulated paste.

## 5. Open questions

- Which LLM does dictation formatting on the server? Is Canto an ASR model, a formatting model, or both? Nothing on the client names it. It needs a network capture, which is out of scope here because we may not call their servers.
- Does `MIXTURE` mean ROVER-style word voting across Whisper, Scribe, Voxtral and Qwen, or an LLM picking among beams? `word_alignments`, `alignment_score` and the `align` step suggest alignment-based fusion.
- Which of the 107 `Language` enum values the server actually supports for ASR and for formatting (the enum values were counted but not mapped one by one).
- How `editing_strength` maps to the LLM behavior, and whether the "no AI formatting" mode still removes fillers. The client skips the `format` step, which suggests raw ASR output plus client-side replacements only.
- How command mode decides between edit and draft. That happens on the server (`/llm/command_mode_route`).
- What the websocket message format is in the dictation fallback path (only the URLs and the fallback event were confirmed). A realtime-style `audio.append` (PCM16, 24 kHz) message exists, which looks like the notetaker/live-translation path using `gpt-realtime-2`.
