import React from 'react';
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  random,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

const INK = '#10243e';
const GOLD = '#f4d34e';
const CREAM = '#fff8e7';
const SKY = '#75c7f2';
const BLUSH = '#efa3be';
const MINT = '#81ddc2';

const clamp = (value: number, min = 0, max = 1) => Math.min(max, Math.max(min, value));

const fadeWindow = (frame: number, start: number, end: number, fadeIn = 14, fadeOut = 14) => {
  const incoming = interpolate(frame, [start, start + fadeIn], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const outgoing = interpolate(frame, [end - fadeOut, end], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return Math.min(incoming, outgoing);
};

const rise = (frame: number, start: number, distance = 42) => {
  const progress = spring({
    frame: frame - start,
    fps: 30,
    config: {damping: 18, mass: 0.8, stiffness: 105},
  });
  return {opacity: clamp(progress), transform: `translateY(${(1 - progress) * distance}px)`};
};

const KMark: React.FC<{size?: number; inverse?: boolean}> = ({size = 94, inverse = false}) => (
  <div
    className="k-mark"
    style={{
      width: size,
      height: size,
      fontSize: size * 0.46,
      color: INK,
      background: inverse ? CREAM : GOLD,
      borderWidth: Math.max(3, size * 0.045),
      borderRadius: size * 0.25,
      boxShadow: `${size * 0.08}px ${size * 0.1}px 0 rgba(16,36,62,.2)`,
    }}
  >
    K
  </div>
);

const Background: React.FC = () => {
  const frame = useCurrentFrame();
  const dawn = interpolate(frame, [0, 75], [0.15, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const nightOpacity = 1 - dawn;
  const driftX = interpolate(frame, [0, 599], [-18, 18]);
  const driftY = interpolate(frame, [0, 599], [-9, 10]);
  const endWarmth = interpolate(frame, [450, 599], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill className="background">
      <Img
        src={staticFile('assets/cloud-day.webp')}
        className="background-image"
        style={{transform: `scale(1.17) translate(${driftX}px, ${driftY}px)`}}
      />
      <Img
        src={staticFile('assets/cloud-night.webp')}
        className="background-image"
        style={{opacity: nightOpacity, transform: `scale(1.18) translate(${-driftX * 0.5}px, ${driftY * 0.4}px)`}}
      />
      <div className="dawn-glow" style={{opacity: 0.48 + dawn * 0.48 + endWarmth * 0.1}} />
      <div className="soft-vignette" />
      <div className="film-grain" style={{opacity: 0.035 + Math.sin(frame * 0.7) * 0.008}} />
    </AbsoluteFill>
  );
};

const FloatingSpecks: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{overflow: 'hidden', pointerEvents: 'none'}}>
      {Array.from({length: 28}).map((_, index) => {
        const x = random(`speck-x-${index}`) * 1920;
        const y = random(`speck-y-${index}`) * 1080;
        const size = 3 + random(`speck-size-${index}`) * 8;
        const speed = 0.12 + random(`speck-speed-${index}`) * 0.3;
        const pulse = 0.32 + 0.38 * Math.sin(frame * 0.035 + index * 1.7);
        return (
          <span
            key={index}
            className="speck"
            style={{
              left: x,
              top: (y - frame * speed + 1200) % 1200 - 60,
              width: size,
              height: size,
              opacity: pulse,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};

const ForegroundClouds: React.FC<{opacity?: number; scale?: number; zIndex?: number}> = ({opacity = 1, scale = 1, zIndex = 10}) => {
  const frame = useCurrentFrame();
  const drift = Math.sin(frame * 0.012) * 16;
  return (
    <Img
      src={staticFile('assets/cloud-clusters.webp')}
      className="foreground-clouds"
      style={{opacity, zIndex, transform: `translateX(${drift}px) scale(${scale})`}}
    />
  );
};

const OpeningScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 0, 82, 18, 15);
  const mark = spring({frame: frame - 5, fps: 30, config: {damping: 13, mass: 0.7, stiffness: 120}});
  const lineWidth = interpolate(frame, [18, 58], [0, 540], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });

  return (
    <AbsoluteFill className="scene opening" style={{opacity}}>
      <div style={{transform: `scale(${0.72 + mark * 0.28}) rotate(${(1 - mark) * -9}deg)`, opacity: clamp(mark)}}>
        <KMark size={110} />
      </div>
      <div className="opening-name" style={rise(frame, 18, 26)}>KINGDOM KIDS</div>
      <div className="opening-rule" style={{width: lineWidth}} />
      <div className="opening-kicker" style={rise(frame, 31, 20)}>A WORLD OF FAITH, WONDER & JOY</div>
    </AbsoluteFill>
  );
};

type ArtCardProps = {
  src: string;
  title: string;
  accent: string;
  x: number;
  y: number;
  rotate: number;
  start: number;
  width?: number;
};

const ArtCard: React.FC<ArtCardProps> = ({src, title, accent, x, y, rotate, start, width = 330}) => {
  const frame = useCurrentFrame();
  const pop = spring({frame: frame - start, fps: 30, config: {damping: 15, mass: 0.75, stiffness: 105}});
  return (
    <div
      className="art-card"
      style={{
        left: x,
        top: y,
        width,
        borderColor: accent,
        opacity: clamp(pop),
        transform: `translateY(${(1 - pop) * 110}px) rotate(${rotate + (1 - pop) * 7}deg) scale(${0.72 + pop * 0.28})`,
      }}
    >
      <div className="art-card-image-wrap">
        <Img src={staticFile(src)} className="art-card-image" />
      </div>
      <div className="art-card-label" style={{background: accent}}>{title}</div>
    </div>
  );
};

const StoriesScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 62, 168, 15, 18);
  const character = spring({frame: frame - 74, fps: 30, config: {damping: 18, mass: 0.9, stiffness: 82}});
  return (
    <AbsoluteFill className="scene" style={{opacity}}>
      <div className="copy-panel copy-panel-left">
        <div className="eyebrow" style={rise(frame, 71, 24)}>STEP INTO THE STORY</div>
        <h1 className="chapter-title" style={rise(frame, 79, 48)}>Discover<br /><span>Bible stories.</span></h1>
        <p className="chapter-copy" style={rise(frame, 91, 26)}>Gentle adventures that make timeless truth feel close, bright and alive.</p>
      </div>
      <div
        className="character character-nia-reading"
        style={{opacity: clamp(character), transform: `translateY(${(1 - character) * 130}px) scale(${0.86 + character * 0.14})`}}
      >
        <div className="character-halo" style={{background: BLUSH}} />
        <Img src={staticFile('assets/nia-reading.png')} />
      </div>
      <ArtCard src="assets/story-noah.png" title="NOAH'S ARK" accent={GOLD} x={1265} y={145} rotate={5} start={94} width={345} />
      <ArtCard src="assets/story-david.png" title="DAVID & GOLIATH" accent={MINT} x={1435} y={490} rotate={-4} start={104} width={310} />
      <div className="chapter-number">01</div>
    </AbsoluteFill>
  );
};

const GamesScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 145, 250, 16, 18);
  const character = spring({frame: frame - 160, fps: 30, config: {damping: 12, mass: 0.7, stiffness: 90}});
  const bounce = Math.sin((frame - 160) * 0.075) * 7;
  return (
    <AbsoluteFill className="scene" style={{opacity}}>
      <div className="copy-panel copy-panel-right">
        <div className="eyebrow" style={rise(frame, 154, 24)}>LEARN WITH A SMILE</div>
        <h1 className="chapter-title" style={rise(frame, 162, 48)}>Learn<br /><span>through play.</span></h1>
        <p className="chapter-copy" style={rise(frame, 174, 26)}>Puzzles, memory games and joyful little challenges built for growing minds.</p>
      </div>
      <div
        className="character character-zuri-jump"
        style={{opacity: clamp(character), transform: `translateY(${(1 - character) * 150 + bounce}px) rotate(${(1 - character) * -5}deg) scale(${0.8 + character * 0.2})`}}
      >
        <div className="character-halo" style={{background: GOLD}} />
        <Img src={staticFile('assets/zuri-jump.png')} />
      </div>
      <ArtCard src="assets/game-puzzle-quest.webp" title="PUZZLE QUEST" accent={BLUSH} x={180} y={155} rotate={-4} start={175} width={320} />
      <ArtCard src="assets/game-david.webp" title="COURAGE QUEST" accent={SKY} x={415} y={510} rotate={4} start={187} width={300} />
      <div className="floating-puzzle puzzle-one">✦</div>
      <div className="floating-puzzle puzzle-two">●</div>
      <div className="chapter-number chapter-number-right">02</div>
    </AbsoluteFill>
  );
};

const TogetherScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 225, 340, 16, 18);
  const kai = spring({frame: frame - 242, fps: 30, config: {damping: 18, stiffness: 80}});
  const nia = spring({frame: frame - 250, fps: 30, config: {damping: 18, stiffness: 80}});
  const zuri = spring({frame: frame - 258, fps: 30, config: {damping: 18, stiffness: 80}});
  return (
    <AbsoluteFill className="scene together" style={{opacity}}>
      <div className="together-copy">
        <div className="eyebrow" style={rise(frame, 234, 20)}>BETTER, TOGETHER</div>
        <h1 className="chapter-title chapter-title-centered" style={rise(frame, 241, 42)}>Grow in faith,<br /><span>side by side.</span></h1>
        <p className="chapter-copy chapter-copy-centered" style={rise(frame, 254, 24)}>Meet Kai, Nia and Zuri—three bright hearts ready for every adventure.</p>
      </div>
      <div className="trio-stage">
        <div className="trio-glow" />
        <Img src={staticFile('assets/kai-wave.png')} className="trio-character trio-kai" style={{opacity: clamp(kai), transform: `translateY(${(1 - kai) * 120}px) scale(${0.85 + kai * 0.15})`}} />
        <Img src={staticFile('assets/nia-wave.png')} className="trio-character trio-nia" style={{opacity: clamp(nia), transform: `translateY(${(1 - nia) * 130}px) scale(${0.85 + nia * 0.15})`}} />
        <Img src={staticFile('assets/zuri-wave.png')} className="trio-character trio-zuri" style={{opacity: clamp(zuri), transform: `translateY(${(1 - zuri) * 140}px) scale(${0.85 + zuri * 0.15})`}} />
      </div>
      <ForegroundClouds opacity={0.92} scale={1.04} />
    </AbsoluteFill>
  );
};

const WorldScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 315, 402, 15, 18);
  const orbit = (frame - 315) * 0.22;
  const items = [
    {label: 'STORIES', symbol: '✦', color: GOLD, angle: 205},
    {label: 'GAMES', symbol: '◆', color: BLUSH, angle: 282},
    {label: 'FAITH', symbol: '♥', color: MINT, angle: 350},
    {label: 'WONDER', symbol: '●', color: SKY, angle: 66},
  ];
  const core = spring({frame: frame - 326, fps: 30, config: {damping: 16, mass: 0.8, stiffness: 88}});
  return (
    <AbsoluteFill className="scene world-scene" style={{opacity}}>
      <div className="world-kicker" style={rise(frame, 320, 20)}>ONE JOYFUL WORLD</div>
      <div className="world-core" style={{opacity: clamp(core), transform: `scale(${0.6 + core * 0.4})`}}>
        <KMark size={112} />
        <div className="world-core-name">KINGDOM KIDS</div>
      </div>
      {items.map((item, index) => {
        const pop = spring({frame: frame - (338 + index * 5), fps: 30, config: {damping: 17, stiffness: 100}});
        const theta = ((item.angle + orbit) * Math.PI) / 180;
        const x = 960 + Math.cos(theta) * 560;
        const y = 560 + Math.sin(theta) * 265;
        return (
          <div
            key={item.label}
            className="world-orb"
            style={{
              left: x - 100,
              top: y - 100,
              background: item.color,
              opacity: clamp(pop),
              transform: `scale(${0.6 + pop * 0.4})`,
            }}
          >
            <b>{item.symbol}</b><span>{item.label}</span>
          </div>
        );
      })}
      <div className="orbit orbit-one" />
      <div className="orbit orbit-two" />
    </AbsoluteFill>
  );
};

type Point = {x: number; y: number};
const cubic = (p0: number, p1: number, p2: number, p3: number, t: number) => {
  const u = 1 - t;
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
};
const cubicDerivative = (p0: number, p1: number, p2: number, p3: number, t: number) =>
  3 * (1 - t) * (1 - t) * (p1 - p0) + 6 * (1 - t) * t * (p2 - p1) + 3 * t * t * (p3 - p2);

type DoveProps = {
  start: number;
  end: number;
  size: number;
  phase: number;
  points: [Point, Point, Point, Point];
  opacity?: number;
  behind?: boolean;
};

const Dove: React.FC<DoveProps> = ({start, end, size, phase, points, opacity = 1}) => {
  const frame = useCurrentFrame();
  if (frame < start || frame > end) return null;
  const t = interpolate(frame, [start, end], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const [a, b, c, d] = points;
  const x = cubic(a.x, b.x, c.x, d.x, t);
  const y = cubic(a.y, b.y, c.y, d.y, t) + Math.sin((frame + phase) * 0.12) * 8;
  const dx = cubicDerivative(a.x, b.x, c.x, d.x, t);
  const dy = cubicDerivative(a.y, b.y, c.y, d.y, t);
  const rotation = Math.atan2(dy, dx) * (180 / Math.PI);
  const spriteFrame = ((Math.floor((frame - start + phase) / 2) % 8) + 8) % 8;
  const width = size * (429 / 458);
  const entry = interpolate(frame, [start, start + 8, end - 8, end], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <div
      className="dove"
      style={{
        width,
        height: size,
        left: x,
        top: y,
        opacity: entry * opacity,
        transform: `translate(-50%, -50%) rotate(${rotation + 180}deg)`,
      }}
    >
      <Img
        src={staticFile('assets/dove-flight-cycle.png')}
        style={{position: 'absolute', height: '100%', width: '800%', maxWidth: 'none', left: `${-spriteFrame * 100}%`, top: 0}}
      />
    </div>
  );
};

const FlockScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = fadeWindow(frame, 375, 468, 10, 13);
  const copyOpacity = fadeWindow(frame, 374, 445, 12, 18);
  return (
    <AbsoluteFill className="scene flock-scene" style={{opacity}}>
      <div className="flock-copy" style={{opacity: copyOpacity}}>
        <div className="eyebrow eyebrow-light" style={rise(frame, 379, 20)}>MADE FOR CURIOUS YOUNG HEARTS</div>
        <div className="flock-line">Stories&nbsp; <span>•</span>&nbsp; Games&nbsp; <span>•</span>&nbsp; Growing together</div>
      </div>
      <Dove start={377} end={442} size={245} phase={0} points={[{x: 2140, y: 620}, {x: 1510, y: 515}, {x: 740, y: 430}, {x: -280, y: 530}]} />
      <Dove start={383} end={445} size={150} phase={4} opacity={0.9} points={[{x: 2070, y: 260}, {x: 1470, y: 200}, {x: 820, y: 270}, {x: -220, y: 210}]} />
      <Dove start={389} end={450} size={195} phase={8} points={[{x: 2160, y: 455}, {x: 1570, y: 360}, {x: 870, y: 505}, {x: -250, y: 420}]} />
      <Dove start={396} end={454} size={170} phase={12} opacity={0.88} points={[{x: 2080, y: 815}, {x: 1420, y: 870}, {x: 750, y: 690}, {x: -250, y: 760}]} />
      <Dove start={405} end={458} size={132} phase={16} opacity={0.82} points={[{x: 2040, y: 660}, {x: 1510, y: 700}, {x: 900, y: 590}, {x: -230, y: 650}]} />
      <ForegroundClouds opacity={0.78} scale={1.08} />
    </AbsoluteFill>
  );
};

const HeroEndScene: React.FC = () => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [435, 458], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const eyebrow = rise(frame, 446, 24);
  const headline = rise(frame, 456, 54);
  const support = rise(frame, 474, 28);
  const endProgress = spring({frame: frame - 526, fps: 30, config: {damping: 18, mass: 0.8, stiffness: 90}});
  const headlineScale = interpolate(frame, [458, 599], [1, 0.94], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const headlineY = interpolate(frame, [515, 555], [0, -105], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill className="scene hero-end" style={{opacity}}>
      <div className="hero-end-content" style={{transform: `translateY(${headlineY}px) scale(${headlineScale})`}}>
        <div className="hero-end-eyebrow" style={eyebrow}>A JOYFUL WORLD OF FAITH & WONDER</div>
        <h1 className="hero-end-title" style={headline}>Let their faith<br /><span>take flight.</span></h1>
        <p className="hero-end-support" style={support}>Bible stories, playful learning and gentle guidance—made for every bright beginning.</p>
      </div>
      <div className="end-card" style={{opacity: clamp(endProgress), transform: `translateY(${(1 - endProgress) * 58}px)`}}>
        <div className="end-card-brand"><KMark size={62} /><span>KINGDOM KIDS</span></div>
        <div className="end-card-divider" />
        <div className="end-card-message"><b>BIG STORIES FOR LITTLE HEARTS</b><span>COMING SOON</span></div>
      </div>
      <div className="sun-ring ring-one" />
      <div className="sun-ring ring-two" />
      <ForegroundClouds opacity={0.78} scale={1.04} zIndex={4} />
    </AbsoluteFill>
  );
};

export const KingdomKidsIntro: React.FC = () => {
  return (
    <AbsoluteFill className="film">
      <Background />
      <FloatingSpecks />
      <OpeningScene />
      <StoriesScene />
      <GamesScene />
      <TogetherScene />
      <WorldScene />
      <FlockScene />
      <HeroEndScene />
      <div className="frame-border" />
    </AbsoluteFill>
  );
};
