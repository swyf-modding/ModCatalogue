// A Discord webhook, when one is configured.
//
// This is an operator's convenience: a failed review should be seen without watching the
// container. It never changes a verdict and never throws into one - a webhook being down is not
// a reason for a review to fail.

const TIMEOUT_MS = 5_000;
const LIMIT = 1_900; // Discord's limit is 2000; leave room for the ellipsis.

/** Post one message to DISCORD_WEBHOOK_URL, if it is set. Never rejects. */
export async function notifyDiscord(content: string): Promise<void> {
  const url = process.env.DISCORD_WEBHOOK_URL;
  if (!url) return;

  const text = content.length > LIMIT ? `${content.slice(0, LIMIT - 1)}…` : content;

  try {
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // The text comes from a review, which can quote a mod. Nothing in it gets to ping a role.
      body: JSON.stringify({ content: text, allowed_mentions: { parse: [] } }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    console.error(`discord: ${String(error)}`);
  }
}
