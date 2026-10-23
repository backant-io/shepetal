import { CLIP, CONTACT, FACETS, HULL, SHADOW_DOWN, SHADOW_UP, TOP } from './keyGeometry';

/**
 * The fn keycap of the approved design. `p` prefixes its classes and SVG ids: 'kc' is the hero key that presses on
 * scroll, 'kd' the small docked key in the corner. Both draw the same key; story.css and the scroll CSS move the parts.
 */
export function KeySvg({ p }: { p: 'kc' | 'kd' }) {
  const id = (name: string) => `${p}-${name}`;
  const url = (name: string) => `url(#${p}-${name})`;
  return (
    <svg className={`${p}-art`} viewBox="-358 -329 906 643" aria-hidden="true" focusable="false">
      <defs>
        <filter id={id('kb1')} x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="2.4" />
        </filter>
        <filter id={id('kb2')} x="-30%" y="-30%" width="160%" height="160%">
          <feGaussianBlur stdDeviation="5" />
        </filter>
        <filter id={id('kb3')} x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="22" />
        </filter>
        <clipPath id={id('kclip')}>
          <path d={CLIP} />
        </clipPath>
        <clipPath id={id('ktop')}>
          <path d={TOP} />
        </clipPath>
        <clipPath id={id('khull')}>
          <path d={HULL} />
        </clipPath>
        <linearGradient id={id('kdish')} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#000" stopOpacity=".02" />
          <stop offset=".07" stopColor="#000" stopOpacity=".13" />
          <stop offset=".32" stopColor="#000" stopOpacity=".03" />
          <stop offset=".62" stopColor="#fff" stopOpacity=".0" />
          <stop offset=".86" stopColor="#fff" stopOpacity=".1" />
          <stop offset=".95" stopColor="#fff" stopOpacity=".2" />
          <stop offset="1" stopColor="#fff" stopOpacity=".05" />
        </linearGradient>
        <linearGradient id={id('kdishx')} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#000" stopOpacity=".05" />
          <stop offset=".3" stopColor="#000" stopOpacity="0" />
          <stop offset=".85" stopColor="#fff" stopOpacity=".04" />
          <stop offset="1" stopColor="#000" stopOpacity=".03" />
        </linearGradient>
        <linearGradient id={id('krim')} x1="-317.2" y1="-298.3" x2="317.2" y2="203.9" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#fff" stopOpacity=".75" />
          <stop offset=".45" stopColor="#fff" stopOpacity=".22" />
          <stop offset="1" stopColor="#fff" stopOpacity=".1" />
        </linearGradient>
        <linearGradient id={id('kao')} x1="0" y1="-88.7" x2="0" y2="203.9" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor="#000" stopOpacity="0" />
          <stop offset=".6" stopColor="#000" stopOpacity=".07" />
          <stop offset="1" stopColor="#000" stopOpacity=".28" />
        </linearGradient>
        <radialGradient id={id('kglow')}>
          <stop offset="0" stopColor="#FFF3E6" stopOpacity=".4" />
          <stop offset="1" stopColor="#FFF3E6" stopOpacity="0" />
        </radialGradient>
      </defs>
      <g className={`${p}-k-shadow`} fill="#2b2117">
        <g className={`${p}-ks-r`}>
          <path d={SHADOW_UP} opacity=".1" filter={url('kb3')} />
          <path d={SHADOW_UP} opacity=".16" filter={url('kb2')} />
        </g>
        <g className={`${p}-ks-d`}>
          <path d={SHADOW_DOWN} opacity=".1" filter={url('kb3')} />
          <path d={SHADOW_DOWN} opacity=".18" filter={url('kb2')} />
        </g>
        <path d={CONTACT} fill="#140e08" opacity=".6" filter={url('kb1')} transform="translate(2 1.5)" />
      </g>
      <g clipPath={url('kclip')}>
        <g className={`${p}-k-idle`}>
          <g className={`${p}-k-cap`}>
            {FACETS.map(([d, fill]) => (
              <path key={d} d={d} fill={fill} stroke={fill} strokeWidth=".9" />
            ))}
            <path d={HULL} fill={url('kao')} clipPath={url('khull')} />
            <path d={TOP} fill="#d7410d" stroke="#d7410d" strokeWidth="5" strokeLinejoin="round" />
            <path d={TOP} fill="#fa4d11" />
            <g clipPath={url('ktop')}>
              <g transform="matrix(0.9659 -0.1664 0.2588 0.6209 0 -128.7)">
                <rect x="-234" y="-228" width="468" height="456" fill={url('kdish')} />
                <rect x="-234" y="-228" width="468" height="456" fill={url('kdishx')} />
                <circle className={`${p}-k-glow`} cx="-172.5" cy="-183" r="90" fill={url('kglow')} />
                <text
                  className={`${p}-k-legend`}
                  x="189"
                  y="-181.5"
                  dominantBaseline="hanging"
                  textAnchor="end"
                  fill="#161512"
                >
                  fn
                </text>
                <g transform="translate(-147 141)" fill="none" stroke="#161512" strokeWidth="5.5" strokeLinecap="round">
                  <circle r="40" />
                  <ellipse rx="17" ry="40" />
                  <path d="M-40 0H40M-33.5 -21H33.5M-33.5 21H33.5" />
                </g>
                <g transform="translate(-172.5 -183)">
                  <rect x="-27" y="-9.5" width="54" height="19" rx="9.5" fill="#000" fillOpacity=".38" />
                  <rect className={`${p}-k-led`} x="-22.5" y="-5" width="45" height="10" rx="5" fill="#FFF6EC" />
                </g>
              </g>
            </g>
            <path d={TOP} fill="none" stroke={url('krim')} strokeWidth="1.6" />
          </g>
        </g>
      </g>
      <circle className={`${p}-k-emit`} cx="105.3" cy="-218.7" r="1" fill="none" />
    </svg>
  );
}
