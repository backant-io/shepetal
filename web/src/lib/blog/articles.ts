import type { Article } from './types';
import { alternatives } from '../../content/blog/wispr-flow-alternatives';
import { bestMac } from '../../content/blog/best-dictation-apps-mac';
import { bestLocal } from '../../content/blog/best-local-dictation-apps';
import { VERSUS } from '../../content/blog/versus';

/** Every article, in the order the index shows them within a shelf. */
export const ARTICLES: Article[] = [bestMac, bestLocal, alternatives, ...VERSUS];

export const bySlug = (slug: string) => ARTICLES.find((a) => a.slug === slug);

export const KIND_LABEL: Record<Article['kind'], string> = {
  comparison: 'Comparison',
  ranking: 'Ranking',
  guide: 'Guide',
};
