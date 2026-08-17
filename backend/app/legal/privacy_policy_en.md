# Privacy Policy

> **Draft.** Replace the `{{bracketed}}` fields with actual values and have this policy reviewed by a lawyer or privacy professional before launch.
> Effective date: {{Effective date, e.g. 2026-08-01}}

Daylog (the "Service") processes users' personal data as described below in accordance with South Korea's Personal Information Protection Act.

## 1. Personal data we collect

- **Account identifier**: The handle entered by the user. We do not separately collect a name, email address, or telephone number.
- **User-created content**: Journal text, voice recordings, chat content, knowledge graphs derived from that content (people, concepts, and statements), and learning questions.
- **Voice speaker data (optional and sensitive)**: If the user consents to speaker identification, voice characteristics (voiceprints) extracted from recordings. This is biometric data and is processed only with separate consent.
- **Automatically collected data**: Technical logs generated while using the Service (kept to the minimum required for error diagnosis).

## 2. Purposes of processing

- Providing core features, including journal and chat refinement, knowledge-graph creation, recall-based chat responses, and learning-question generation
- Speaker identification (with consent): distinguishing and attributing speakers in conversations
- Diagnosing errors and improving service quality

## 3. Overseas transfer (outsourced processing)

The Service entrusts personal-data processing to the overseas providers below for AI processing. Transferred data is used only for the stated processing purposes.

| Recipient | Country | Data transferred | Purpose | Method | Retention and use period |
|---|---|---|---|---|---|
| OpenAI, L.L.C. | United States | Journal and chat text, audio (when converted to text), and names of people and concepts | Speech recognition (STT), text refinement and translation, knowledge extraction, embeddings, chat, and question generation | Sent through an HTTPS API when the feature is used | Deleted without delay after processing (may be retained for up to 30 days for abuse monitoring under the provider's policy, then deleted; inputs are not used to train models) |
| Microsoft Corporation | United States | Learning-question text | Text-to-speech (TTS) | Sent through an API when the feature is used | Not retained after processing |
| Deepgram, Inc. (optional) | United States | Voice recordings | Speaker diarization (only with consent and when the feature is enabled) | Sent through an API when the feature is used | Not retained after processing |

The transfer occurs when the user uses the relevant feature. Users may refuse an overseas transfer, but the related AI features will then be unavailable.

## 4. Processing of sensitive data

- **Voice speaker characteristics (voiceprints)**: As biometric data, these are created and used only when the user separately consents to speaker identification. If consent is withdrawn, further creation stops and stored characteristics are deleted.
- Journals may contain sensitive information such as health or beliefs. The Service processes it only for the user's own journaling and recall and does not provide it to third parties.

## 5. Retention and deletion

- User content is retained while the account remains active and is deleted without delay when the user deletes an item or closes the account.
- When an account is closed, database records and stored audio, files, and processing logs are deleted.
- Diagnostic debug logs are retained for no more than seven days. Original prompts and audio are not retained in the production environment.

## 6. Your rights and how to exercise them

Users may exercise the following rights at any time:

- **Access and export**: Download all retained data as JSON through "Export my data" in the app.
- **Correction and deletion**: Delete individual journals, nodes, or chats, or delete everything by closing the account.
- **Withdrawal of consent**: Withdraw optional consent, including speaker-identification consent, in Settings.

## 7. Security measures

- Encryption in transit (HTTPS/TLS), token-based access control, and account-level data isolation
- Least-privilege access and minimal collection and retention of processing logs

## 8. Privacy officer and policy changes

- Privacy officer: {{Name}} ({{Contact email}})
- This policy takes effect on {{Effective date}}. Changes will be announced in the app.
