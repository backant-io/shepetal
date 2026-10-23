import { describe, expect, it, vi } from 'vitest';
import { upsertUser } from './account';
import { db, useTestDb } from './test-db';
import { optedIn, recordTrialEmailsOptIn, TRIAL_EMAILS_FIELD, TRIAL_EMAILS_LABEL } from './trial-emails';

vi.mock('./db', () => import('./test-db'));
useTestDb();

const T = Date.parse('2026-11-01T12:00:00.000Z');
const optIn = (email: string) => db().prepare('SELECT trial_emails_at FROM users WHERE email = ?1').bind(email).first<{ trial_emails_at: string | null }>();

describe('the trial emails opt-in', () => {
  // Brand voice: plain, short, lowercase shepetal, no em dash.
  it('asks in the approved words', () => {
    expect(TRIAL_EMAILS_LABEL).toBe('Send me three short emails about my trial.');
    expect(TRIAL_EMAILS_FIELD).toBe('trial_emails');
  });

  // An unticked checkbox posts nothing: only the tick is consent.
  it('reads only a ticked box as consent', () => {
    expect(optedIn(new URLSearchParams({ trial_emails: 'yes' }))).toBe(true);
    expect(optedIn(new URLSearchParams())).toBe(false);
    expect(optedIn(new URLSearchParams({ trial_emails: 'on' }))).toBe(false);
    expect(optedIn(null)).toBe(false);
  });

  it('starts every new account without consent', async () => {
    await upsertUser('new@example.com');
    expect(await optIn('new@example.com')).toEqual({ trial_emails_at: null });
  });

  it('records the time of the tick, for a new user or one already signed up', async () => {
    await upsertUser('A@example.com');
    expect(await recordTrialEmailsOptIn('a@EXAMPLE.com', T)).toBe(true);
    expect(await optIn('a@example.com')).toEqual({ trial_emails_at: '2026-11-01T12:00:00.000Z' });
    expect(await recordTrialEmailsOptIn('nobody@example.com', T)).toBe(false);
  });

  // Ticking the box again after unsubscribing is a new consent, given on purpose.
  it('lifts an earlier unsubscribe when the box is ticked again', async () => {
    const { id, email } = await upsertUser('back@example.com');
    await db().prepare('INSERT INTO email_unsubscribes (user_id) VALUES (?1)').bind(id).run();
    await recordTrialEmailsOptIn(email, T);
    expect(await db().prepare('SELECT 1 FROM email_unsubscribes WHERE user_id = ?1').bind(id).first()).toBeNull();
  });
});
