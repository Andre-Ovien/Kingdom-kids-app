import React from 'react';
import {Composition} from 'remotion';
import {KingdomKidsIntro} from './KingdomKidsIntro';
import './styles.css';

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="KingdomKidsIntro"
      component={KingdomKidsIntro}
      durationInFrames={600}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
