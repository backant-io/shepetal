import { ImageResponse } from 'next/og';
import { SHUSH_SVG } from '@/components/shush';

export const alt = 'Shepetal: hold fn, talk, done. Dictation that runs fully on your Mac.';
export const size = { width: 1200, height: 630 };
export const contentType = 'image/png';

export default function OpenGraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          padding: '72px 80px',
          background: '#161a2e',
          color: '#e8eaf2',
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', fontSize: 132, lineHeight: 0.9, letterSpacing: -4 }}>
          <span>hold fn,</span>
          <span>talk,</span>
          <span>done.</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 24, fontSize: 34, color: '#8d93b0' }}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={`data:image/svg+xml,${encodeURIComponent(SHUSH_SVG)}`}
            width={72}
            height={72}
            alt=""
            style={{ borderRadius: 36, boxShadow: '0 0 0 5px #ff453a' }}
          />
          <span style={{ color: '#e8eaf2' }}>shepetal</span>
          <span>Dictation that runs fully on your Mac</span>
        </div>
      </div>
    ),
    size,
  );
}
