---
name: remotion-templates
description: Remotion composition templates and patterns for video_compose_dynamic. Use when building the final video in Phase 5.
---

# Remotion Composition Templates

## When to Use
Use these templates during Phase 5 (Produce) when composing the final video with `video_compose_dynamic`.

## Available APIs

In `video_compose_dynamic` code, these are available:
- **Hooks**: `useCurrentFrame()`, `useVideoConfig()`, `useState`, `useEffect`, `useCallback`, `useMemo`, `useRef`
- **Animation**: `interpolate(frame, inputRange, outputRange)`, `spring({frame, fps, config})`, `Easing`
- **Components**: `AbsoluteFill`, `Sequence`, `Series`, `Loop`, `Video`, `Audio`, `Img`
- **Utilities**: `random(seed)`, `interpolateColors(frame, inputRange, colorRange)`

## Template: Title Card with Fade

```jsx
return function TitleCard() {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const opacity = interpolate(frame, [0, 30], [0, 1], { extrapolateRight: 'clamp' });
  const scale = spring({ frame, fps, config: { damping: 200 } });

  return (
    <AbsoluteFill style={{ backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }}>
      <h1 style={{
        color: 'white',
        fontSize: 72,
        fontWeight: 'bold',
        opacity,
        transform: `scale(${scale})`,
        textAlign: 'center',
        padding: 40,
      }}>
        Your Title Here
      </h1>
    </AbsoluteFill>
  );
};
```

## Template: Text with Subtitle

```jsx
return function TitleSubtitle() {
  const frame = useCurrentFrame();
  const titleOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: 'clamp' });
  const subtitleOpacity = interpolate(frame, [15, 35], [0, 1], { extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ backgroundColor: '#1a1a2e', justifyContent: 'center', alignItems: 'center' }}>
      <h1 style={{ color: '#e94560', fontSize: 64, opacity: titleOpacity, margin: 0 }}>Main Title</h1>
      <p style={{ color: '#eee', fontSize: 28, opacity: subtitleOpacity, marginTop: 16 }}>Subtitle text goes here</p>
    </AbsoluteFill>
  );
};
```

## Template: Lower Third (name tag overlay)

```jsx
return function LowerThird() {
  const frame = useCurrentFrame();
  const slideIn = interpolate(frame, [0, 20], [-300, 0], { extrapolateRight: 'clamp' });
  const fadeOut = interpolate(frame, [80, 90], [1, 0], { extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ justifyContent: 'flex-end', padding: 60, opacity: fadeOut }}>
      <div style={{
        transform: `translateX(${slideIn}px)`,
        backgroundColor: 'rgba(0,0,0,0.7)',
        padding: '12px 24px',
        borderLeft: '4px solid #ff6b35',
        borderRadius: 4,
      }}>
        <div style={{ color: 'white', fontSize: 28, fontWeight: 'bold' }}>Speaker Name</div>
        <div style={{ color: '#ccc', fontSize: 18 }}>Title / Role</div>
      </div>
    </AbsoluteFill>
  );
};
```

## Template: Clip Sequence with Transitions

```jsx
return function ClipSequence() {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Define clip timing (adjust based on actual clips)
  const clips = [
    { src: 'asset://clips/clip0.mov', start: 0, dur: 5 * fps },
    { src: 'asset://clips/clip1.mov', start: 5 * fps, dur: 4 * fps },
    { src: 'asset://clips/clip2.mov', start: 9 * fps, dur: 3 * fps },
  ];

  return (
    <AbsoluteFill>
      {clips.map((clip, i) => (
        <Sequence key={i} from={clip.start} durationInFrames={clip.dur}>
          <AbsoluteFill>
            <Video src={clip.src} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          </AbsoluteFill>
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
```

## Template: Countdown Timer

```jsx
return function Countdown() {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const seconds = Math.max(0, 3 - Math.floor(frame / fps));
  const progress = (frame % fps) / fps;
  const scale = interpolate(progress, [0, 0.5, 1], [1.5, 1, 0.8]);

  return (
    <AbsoluteFill style={{ backgroundColor: '#000', justifyContent: 'center', alignItems: 'center' }}>
      <div style={{
        color: 'white',
        fontSize: 200,
        fontWeight: 'bold',
        transform: `scale(${scale})`,
        opacity: seconds > 0 ? 1 : 0,
      }}>
        {seconds}
      </div>
    </AbsoluteFill>
  );
};
```

## Template: Split Screen (Side by Side)

```jsx
return function SplitScreen() {
  return (
    <AbsoluteFill style={{ flexDirection: 'row' }}>
      <div style={{ flex: 1, overflow: 'hidden' }}>
        <Video src="asset://clips/clip0.mov" style={{ width: '200%', height: '100%', objectFit: 'cover' }} />
      </div>
      <div style={{ width: 4, backgroundColor: 'white' }} />
      <div style={{ flex: 1, overflow: 'hidden' }}>
        <Video src="asset://clips/clip1.mov" style={{ width: '200%', height: '100%', objectFit: 'cover', marginLeft: '-100%' }} />
      </div>
    </AbsoluteFill>
  );
};
```

## Template: End Credits

```jsx
return function Credits() {
  const frame = useCurrentFrame();
  const { height } = useVideoConfig();
  const scrollY = interpolate(frame, [0, 300], [height, -600]);

  return (
    <AbsoluteFill style={{ backgroundColor: '#000' }}>
      <div style={{ transform: `translateY(${scrollY}px)`, textAlign: 'center', padding: 40 }}>
        <h1 style={{ color: 'white', fontSize: 48, marginBottom: 40 }}>Thank You</h1>
        <p style={{ color: '#aaa', fontSize: 24, lineHeight: 2 }}>
          Directed by AI Production Agent<br/>
          Filmed on iPhone<br/>
          Edited with Remotion<br/>
          Powered by Copilot
        </p>
      </div>
    </AbsoluteFill>
  );
};
```

## Tips

- Always set `extrapolateRight: 'clamp'` on interpolations to prevent values going beyond your target range
- Use `spring()` for natural-feeling motion (buttons, text entrance)
- Use `Sequence` to place elements at specific times
- Use `Series` for sequential items that automatically follow each other
- Access clip files as `asset://clips/clip0.mov`, `asset://clips/clip1.mov`, etc.
- Set appropriate `durationInFrames` in the tool call based on total video length
