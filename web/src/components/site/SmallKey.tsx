import { KeySvg } from '@/components/story/KeySvg';

/** The fn key at the size it docks to on the landing page. Inside `.s-press` it presses while the orange action is pointed at. */
export function SmallKey() {
  return (
    <span className="s-key" aria-hidden="true">
      <KeySvg p="kd" />
    </span>
  );
}
