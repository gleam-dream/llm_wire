# Context map

This map indexes the three context chapters of the LLM Wire design. Each context owns the model, lifecycle and vocabulary of one provider interaction family. The root design owns cross-context foundation, system view, verification and the end-to-end walkthrough.

## Contexts

| Context            | Ownership                                                                                                                                                                 | Design                                     | Vocabulary                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------ |
| **Generation**     | Request admission, caller-owned conversation, provider interpretation, the owned semantic stream, and the failure, retry and observation evidence shared by every family. | [design](design/generation/design.typ)     | [terms](design/generation/CONTEXT.typ)     |
| **Classification** | Typed questions, pure classification wires, shared candidate admission and durable receipt reconstruction.                                                                | [design](design/classification/design.typ) | [terms](design/classification/CONTEXT.typ) |
| **Transcription**  | Inline audio admission and completed-text decoding through the caller's HTTP client.                                                                                      | [design](design/transcription/design.typ)  | [terms](design/transcription/CONTEXT.typ)  |

## Relationships

- **Generation → Classification — conformist.** Classification conforms to the Failure, send evidence, retry advice and observation vocabulary that Generation owns, and redefines none of it.
- **Generation → Transcription — conformist.** Transcription conforms to the same Failure, send evidence and observation vocabulary and adds its own audio and settings model.
