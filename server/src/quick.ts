// Device actions for /v1/suggest: typed text that may be an event, a reminder or a note. Regex only, no model call.
// The phone settles clear cases itself ("meeting with Ana tomorrow 3pm"); only an unclear sentence reaches here.
const TASK = /\b(?:remind|call|ring|text|email|buy|pick up|send|order|book|check|follow up|ping|meet\w*|appointment|appt|dentist|doctor|lunch|dinner|coffee|interview|move|reschedule|cancel|don'?t forget|need to|todo|to-?do)\b/i;

/** The last sentence the owner typed. */
export const lastSentence = (text: string) => (text.trim().split('\n').pop() ?? '').split(/(?<=[.!?])\s+(?=\S)/).pop()!.trim();

/** A capitalized word after the first: likely a person ("Ana", "Ana's"). */
export const nameIn = (sentence: string) =>
  sentence.split(/\s+/).slice(1).map((w) => w.replace(/['’]s$|[^\p{L}]/gu, '')).find((w) => w.length > 1 && /^\p{Lu}/u.test(w) && /\p{Ll}/u.test(w)) ?? null;

/**
 * True when the sentence has action-ish signals: a task or meeting word, a time or number, a name, or a question.
 * Plain chat ("lol ok see you") has none, so it costs no call. Same rule as SmartDetect.maybe on the phone.
 */
export function deviceSignal(text: string): boolean {
  const s = lastSentence(text);
  if (s.split(/\s+/).filter(Boolean).length < 4) return false;
  return TASK.test(s) || /\d/.test(s) || nameIn(s) !== null || s.endsWith('?');
}

/** The words a device chip came from: the name, else the task word, else the sentence start. */
export const deviceTrigger = (sentence: string) => nameIn(sentence) ?? sentence.match(TASK)?.[0] ?? sentence.split(/\s+/).slice(0, 3).join(' ');

/** "can we move Ana's thing?" gives "Move Ana's thing": the lead-in and the question mark go. */
export function deviceTitle(sentence: string): string {
  const t = sentence
    .replace(/^(?:(?:hey|ok|okay|so|and|also|please)[\s,]+)*(?:(?:can|could|shall|should) (?:we|you|i)\s+|(?:i|we) (?:need|have|want) to\s+|remind me to\s+|don'?t forget to\s+|let'?s\s+)?/i, '')
    .replace(/[\s?!.]+$/, '')
    .trim();
  return t ? t[0].toUpperCase() + t.slice(1) : '';
}
