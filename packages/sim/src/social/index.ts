// Social: mad-libs comments and account-name checks.
export {
  TEMPLATES, WORDS_VERSION, MAX_COMMENT_CHARS, SLOT_KINDS, STATIC_WORDS,
  vocabulary, vocabularyVersion, worldWords, validateComment, renderComment, templateById, incidentPhrase,
  type CommentTemplate, type CommentDraft, type SlotKind, type TemplateKind,
} from "./comments.ts";
export { checkAccountName, isReservedName, isProfane, normalizeName, NAME_MIN, NAME_MAX } from "./names.ts";
