// Engine_Terra
// Percussion synthesizer combining:
//   UDO DMNO:     hybrid oscillators, binaural stereo, multi-mode VCF
//   Space Drum:   (sequencer in Lua)
//   Esu Trifecta: 3-slot serial FX chain with clock sync + ducking
//   Nymira:       FM partials, subtractive, noise/filtered synthesis
//
// 6 percussion voices, each selectable between 3 synthesis modes
// Signal: voice -> fxBus -> fx1 -> fx2 -> fx3 -> duck -> out

Engine_Terra : CroneEngine {

    var pg;
    var fxGroup;
    var duckGroup;
    var voiceSynths;
    var fxBus;
    var fx1Synth, fx2Synth, fx3Synth;
    var duckSynth;
    var duckBus;
    var duckEnvSynth;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        fxBus = Bus.audio(context.server, 2);
        duckBus = Bus.control(context.server, 1);

        pg = ParGroup.new(context.xg);
        fxGroup = Group.after(pg);
        duckGroup = Group.after(fxGroup);

        voiceSynths = Array.fill(6, { nil });

        // ======== VOICE SYNTHDEFS ========

        // --- Mode 0: FM Percussion (Nymira-inspired 7-partial metallic) ---
        SynthDef(\tf_fm, {
            arg out, freq=200, amp=0.5, pan=0, detune=0,
                partial1=1.0, partial2=0.5, partial3=0.3, partial4=0.2,
                partial5=0.1, partial6=0.08, partial7=0.05,
                fmIndex=1.0, fmRatio=1.414,
                pitchEnvAmt=2, pitchDecay=0.05,
                attack=0.001, decay=0.3, curve=(-6),
                filterFreq=6000, filterRes=0.3, filterType=0,
                spread=0.3;

            var sig, env, pitchEnv, modulator;
            var amps;
            var sigL, sigR;

            pitchEnv = EnvGen.kr(Env.perc(0.001, pitchDecay, pitchEnvAmt, -8));
            freq = freq * (1 + pitchEnv);

            modulator = SinOsc.ar(freq * fmRatio) * fmIndex * freq;

            amps = [partial1, partial2, partial3, partial4, partial5, partial6, partial7];
            sig = Mix.fill(7, { arg i;
                SinOsc.ar(freq * (i + 1) + modulator, 0, amps[i])
            });
            // normalize: divide by sum of partial amps, then boost
            sig = sig * 1.5 / amps.sum.max(0.1);

            env = EnvGen.kr(Env.perc(attack, decay, 1, curve), doneAction: Done.freeSelf);

            sig = Select.ar(filterType, [
                RLPF.ar(sig, filterFreq.clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)),
                RHPF.ar(sig, filterFreq.clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)),
                BPF.ar(sig, filterFreq.clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)) * 3
            ]);

            sig = sig * env * amp;

            sigL = DelayN.ar(sig, 0.01, spread * 0.005);
            sigR = DelayN.ar(sig, 0.01, spread * 0.003 + (detune.abs * 0.001));
            sig = Pan2.ar(sig, pan) + [sigL * spread * 0.4, sigR * spread * 0.4];
            sig = LeakDC.ar(sig);

            Out.ar(out, sig);
        }).add;

        // --- Mode 1: Subtractive (classic analog drum synthesis) ---
        SynthDef(\tf_sub, {
            arg out, freq=200, amp=0.5, pan=0, detune=0,
                shape=0, pulseWidth=0.5,
                pitchEnvAmt=4, pitchDecay=0.03,
                attack=0.001, decay=0.3, curve=(-6),
                noiseAmt=0.0, noiseDecay=0.05,
                filterFreq=4000, filterRes=0.5, filterType=0,
                filterEnvAmt=2000, filterDecay=0.1,
                spread=0.3;

            var sig, osc, noise, env, pitchEnv, filterEnv;
            var sigL, sigR;

            pitchEnv = EnvGen.kr(Env.perc(0.001, pitchDecay, pitchEnvAmt, -8));
            freq = freq * (1 + pitchEnv);

            osc = SelectX.ar(shape * 3, [
                SinOsc.ar(freq + (detune * 0.5)),
                LFTri.ar(freq + (detune * 0.5)),
                LFSaw.ar(freq + (detune * 0.5)),
                Pulse.ar(freq + (detune * 0.5), pulseWidth)
            ]);

            noise = WhiteNoise.ar * EnvGen.kr(Env.perc(0.001, noiseDecay, 1, -8));
            sig = osc + (noise * noiseAmt);

            filterEnv = EnvGen.kr(Env.perc(0.001, filterDecay, filterEnvAmt, -6));

            sig = Select.ar(filterType, [
                RLPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)),
                RHPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)),
                BPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.05)) * 3
            ]);

            env = EnvGen.kr(Env.perc(attack, decay, 1, curve), doneAction: Done.freeSelf);
            sig = sig * env * amp * 1.5;  // volume boost

            sigL = DelayN.ar(sig, 0.01, spread * 0.004);
            sigR = DelayN.ar(sig, 0.01, spread * 0.002 + (detune.abs * 0.0005));
            sig = Pan2.ar(sig, pan) + [sigL * spread * 0.4, sigR * spread * 0.4];
            sig = LeakDC.ar(sig);

            Out.ar(out, sig);
        }).add;

        // --- Mode 2: Noise/Filtered (textured, granular-inspired hits) ---
        SynthDef(\tf_noise, {
            arg out, freq=200, amp=0.5, pan=0, detune=0,
                noiseType=0, crackle=0.5,
                grainRate=40, grainDur=0.03,
                pitchEnvAmt=0, pitchDecay=0.05,
                attack=0.001, decay=0.3, curve=(-6),
                filterFreq=3000, filterRes=0.8, filterType=0,
                filterEnvAmt=4000, filterDecay=0.08,
                ringFreq=0, ringAmt=0,
                spread=0.3;

            var sig, env, filterEnv, ring;
            var sigL, sigR;

            sig = SelectX.ar(noiseType * 2, [
                WhiteNoise.ar,
                PinkNoise.ar,
                Crackle.ar(crackle.linlin(0, 1, 1.0, 2.0)) + Dust2.ar(grainRate * 10) * 0.5
            ]);

            // granular gating (wider pulses for more volume)
            sig = sig * LFPulse.ar(grainRate.max(1), 0, (grainDur * grainRate.max(1)).clip(0.1, 0.95));

            // pitched resonance
            sig = sig + CombL.ar(sig, 0.05, (1/freq.max(20)).min(0.05), 0.08) * 0.6;

            filterEnv = EnvGen.kr(Env.perc(0.001, filterDecay, filterEnvAmt, -6));

            sig = Select.ar(filterType, [
                RLPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.03)),
                RHPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.03)),
                BPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.linlin(0, 1, 1, 0.03)) * 4
            ]);

            ring = SinOsc.ar(ringFreq.max(1));
            sig = (sig * (1 - ringAmt)) + (sig * ring * ringAmt);

            env = EnvGen.kr(Env.perc(attack, decay, 1, curve), doneAction: Done.freeSelf);
            sig = sig * env * amp * 2.0;  // volume boost (noise is inherently quieter)

            sigL = DelayN.ar(sig, 0.01, spread * 0.006);
            sigR = DelayN.ar(sig, 0.01, spread * 0.001);
            sig = Pan2.ar(sig, pan) + [sigL * spread * 0.4, sigR * spread * 0.4];
            sig = LeakDC.ar(sig);

            Out.ar(out, sig);
        }).add;


        // ======== FX SYNTHDEFS (Esu's Trifecta-inspired) ========

        SynthDef(\tf_fx_bypass, {
            arg bus;
            ReplaceOut.ar(bus, In.ar(bus, 2));
        }).add;

        SynthDef(\tf_fx_delay, {
            arg bus, time=0.3, feedback=0.4, mix=0.3, color=0.5;
            var sig, wet, fb;
            sig = In.ar(bus, 2);
            fb = LocalIn.ar(2) * feedback;
            fb = LPF.ar(fb, color.linexp(0, 1, 600, 12000));
            fb = fb.tanh;
            wet = DelayC.ar(sig + fb, 2.0, time.clip(0.001, 2.0));
            LocalOut.ar(wet);
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_reverb, {
            arg bus, size=0.7, decayTime=0.5, mix=0.25, shimmer=0;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = FreeVerb2.ar(sig[0], sig[1], 1.0, size, 0.5);
            wet = wet + (PitchShift.ar(wet, 0.2, 2.0, 0, 0.01) * shimmer * 0.3);
            wet = LPF.ar(wet, 12000);
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_filter, {
            arg bus, freq=2000, res=0.5, mix=1.0, lfoRate=0.1;
            var sig, wet, lfo;
            sig = In.ar(bus, 2);
            lfo = SinOsc.kr(lfoRate).range(0.5, 2.0);
            wet = RLPF.ar(sig, (freq * lfo).clip(40, 18000), res.linlin(0, 1, 1, 0.05));
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_crush, {
            arg bus, bits=12, rate=44100, mix=0.5, drive=0;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = Decimator.ar(sig, rate, bits);
            wet = (wet * (1 + (drive * 8))).tanh;
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_ring, {
            arg bus, freq=200, depth=0.5, mix=0.5, lfoRate=0;
            var sig, wet, mod;
            sig = In.ar(bus, 2);
            mod = SinOsc.ar(freq + (SinOsc.kr(lfoRate) * freq * 0.1));
            wet = sig * ((1 - depth) + (mod * depth));
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_chorus, {
            arg bus, rate=0.5, depth=0.003, mix=0.4;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = Mix.fill(3, { arg i;
                var r = rate * (1 + (i * 0.1));
                var d = depth * (1 + (i * 0.3));
                DelayC.ar(sig, 0.05, SinOsc.kr(r, i * 1.2).range(0.001, d.max(0.002)) + 0.003)
            }) / 3;
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        SynthDef(\tf_fx_phaser, {
            arg bus, rate=0.3, depth=0.7, mix=0.5;
            var sig, wet, mod;
            sig = In.ar(bus, 2);
            mod = SinOsc.kr(rate).range(200, 4000);
            wet = sig;
            4.do({ arg i;
                wet = AllpassN.ar(wet, 0.01, (mod * (i + 1) / 4).reciprocal.clip(0.0001, 0.01), 0);
            });
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix * depth));
        }).add;

        // ======== DUCK / SIDECHAIN ========
        SynthDef(\tf_duck, {
            arg bus, duckAmt=0, duckDecay=0.15, duckIn;
            var sig, duckEnv;
            sig = In.ar(bus, 2);
            duckEnv = In.kr(duckIn, 1);
            sig = sig * (1 - (duckEnv * duckAmt));
            ReplaceOut.ar(bus, sig);
        }).add;

        SynthDef(\tf_duck_env, {
            arg out, decay=0.15;
            var trig, env;
            trig = \trig.tr(0);
            env = EnvGen.kr(Env.perc(0.001, decay, 1, -4), trig);
            Out.kr(out, env);
        }).add;

        // bus copy
        SynthDef(\tf_bus_copy, {
            arg in, out;
            Out.ar(out, In.ar(in, 2));
        }).add;

        // output limiter/compressor — final stage
        SynthDef(\tf_output, {
            arg bus, threshold=0.6, ratio=4, makeup=1.2;
            var sig, compressed;
            sig = In.ar(bus, 2);
            compressed = Compander.ar(sig, sig,
                thresh: threshold,
                slopeBelow: 1,
                slopeAbove: 1/ratio,
                clampTime: 0.002,
                relaxTime: 0.08
            );
            compressed = Limiter.ar(compressed * makeup, 0.95, 0.005);
            ReplaceOut.ar(bus, compressed);
        }).add;

        context.server.sync;

        // ======== STARTUP ========

        duckEnvSynth = Synth(\tf_duck_env, [\out, duckBus, \decay, 0.15], pg);

        // bus copy at head of fx chain
        Synth(\tf_bus_copy, [\in, fxBus, \out, context.out_b], fxGroup, \addToHead);

        context.server.sync;

        fx1Synth = Synth(\tf_fx_bypass, [\bus, context.out_b], fxGroup, \addToTail);
        fx2Synth = Synth.after(fx1Synth, \tf_fx_bypass, [\bus, context.out_b]);
        fx3Synth = Synth.after(fx2Synth, \tf_fx_bypass, [\bus, context.out_b]);

        duckSynth = Synth(\tf_duck, [\bus, context.out_b, \duckAmt, 0, \duckIn, duckBus], duckGroup);

        // output compressor/limiter — always last in chain
        Synth.after(duckSynth, \tf_output, [\bus, context.out_b]);

        // ======== COMMANDS ========

        this.addCommand("trig", "iifff", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var mode = msg[2].asInteger.clip(0, 2);
            var freq = msg[3].asFloat;
            var amp = msg[4].asFloat;
            var pan = msg[5].asFloat;
            var synthName;

            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].free;
                voiceSynths[voice] = nil;
            });

            synthName = [\tf_fm, \tf_sub, \tf_noise][mode];
            voiceSynths[voice] = Synth(synthName, [
                \out, fxBus, \freq, freq, \amp, amp, \pan, pan
            ], pg);
        });

        this.addCommand("voice_param", "isf", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var param = msg[2].asString.asSymbol;
            var val = msg[3].asFloat;
            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].set(param, val);
            });
        });

        this.addCommand("trig_full", "iifffffffffff", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var mode = msg[2].asInteger.clip(0, 2);
            var freq = msg[3].asFloat;
            var amp = msg[4].asFloat;
            var pan = msg[5].asFloat;
            var decay = msg[6].asFloat;
            var filterFreq = msg[7].asFloat;
            var filterRes = msg[8].asFloat;
            var filterType = msg[9].asFloat;
            var pitchEnvAmt = msg[10].asFloat;
            var pitchDecay = msg[11].asFloat;
            var spread = msg[12].asFloat;
            var detune = msg[13].asFloat;
            var synthName;

            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].free;
                voiceSynths[voice] = nil;
            });

            synthName = [\tf_fm, \tf_sub, \tf_noise][mode];
            voiceSynths[voice] = Synth(synthName, [
                \out, fxBus, \freq, freq, \amp, amp, \pan, pan,
                \decay, decay, \filterFreq, filterFreq, \filterRes, filterRes,
                \filterType, filterType.asInteger,
                \pitchEnvAmt, pitchEnvAmt, \pitchDecay, pitchDecay,
                \spread, spread, \detune, detune
            ], pg);
        });

        // extended trigger with FM/Sub/Noise specific params
        this.addCommand("trig_ext", "iiffffffffffffff", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var mode = msg[2].asInteger.clip(0, 2);
            var freq = msg[3].asFloat;
            var amp = msg[4].asFloat;
            var pan = msg[5].asFloat;
            var decay = msg[6].asFloat;
            var filterFreq = msg[7].asFloat;
            var filterRes = msg[8].asFloat;
            var filterType = msg[9].asFloat;
            var pitchEnvAmt = msg[10].asFloat;
            var pitchDecay = msg[11].asFloat;
            var spread = msg[12].asFloat;
            var detune = msg[13].asFloat;
            var extra1 = msg[14].asFloat;  // FM: fmIndex | Sub: shape | Noise: noiseType
            var extra2 = msg[15].asFloat;  // FM: fmRatio | Sub: noiseAmt | Noise: grainRate
            var extra3 = msg[16].asFloat;  // FM: (unused) | Sub: filterEnvAmt | Noise: ringAmt
            var synthName, extraArgs;

            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].free;
                voiceSynths[voice] = nil;
            });

            synthName = [\tf_fm, \tf_sub, \tf_noise][mode];

            extraArgs = case
            { mode == 0 } { [\fmIndex, extra1, \fmRatio, extra2] }
            { mode == 1 } { [\shape, extra1, \noiseAmt, extra2, \filterEnvAmt, extra3] }
            { mode == 2 } { [\noiseType, extra1, \grainRate, extra2, \ringAmt, extra3] };

            voiceSynths[voice] = Synth(synthName, [
                \out, fxBus, \freq, freq, \amp, amp, \pan, pan,
                \decay, decay, \filterFreq, filterFreq, \filterRes, filterRes,
                \filterType, filterType.asInteger,
                \pitchEnvAmt, pitchEnvAmt, \pitchDecay, pitchDecay,
                \spread, spread, \detune, detune
            ] ++ (extraArgs ? []), pg);
        });

        this.addCommand("duck_trig", "", { arg msg;
            duckEnvSynth.set(\trig, 1);
        });

        this.addCommand("duck_amt", "f", { arg msg;
            duckSynth.set(\duckAmt, msg[1].asFloat);
        });
        this.addCommand("duck_decay", "f", { arg msg;
            duckSynth.set(\duckDecay, msg[1].asFloat);
            duckEnvSynth.set(\decay, msg[1].asFloat);
        });

        this.addCommand("fx_set", "ii", { arg msg;
            var slot = msg[1].asInteger.clip(0, 2);
            var fxType = msg[2].asInteger.clip(0, 7);
            var synthName = [\tf_fx_bypass, \tf_fx_delay, \tf_fx_reverb, \tf_fx_filter,
                \tf_fx_crush, \tf_fx_ring, \tf_fx_chorus, \tf_fx_phaser][fxType];
            var oldSynth, newSynth;

            case
            { slot == 0 } {
                oldSynth = fx1Synth;
                newSynth = Synth.replace(oldSynth, synthName, [\bus, context.out_b]);
                fx1Synth = newSynth;
            }
            { slot == 1 } {
                oldSynth = fx2Synth;
                newSynth = Synth.replace(oldSynth, synthName, [\bus, context.out_b]);
                fx2Synth = newSynth;
            }
            { slot == 2 } {
                oldSynth = fx3Synth;
                newSynth = Synth.replace(oldSynth, synthName, [\bus, context.out_b]);
                fx3Synth = newSynth;
            };
        });

        this.addCommand("fx_param", "isf", { arg msg;
            var slot = msg[1].asInteger.clip(0, 2);
            var param = msg[2].asString.asSymbol;
            var val = msg[3].asFloat;
            case
            { slot == 0 } { fx1Synth.set(param, val) }
            { slot == 1 } { fx2Synth.set(param, val) }
            { slot == 2 } { fx3Synth.set(param, val) };
        });

        this.addCommand("partials", "ifffffff", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].set(
                    \partial1, msg[2].asFloat,
                    \partial2, msg[3].asFloat,
                    \partial3, msg[4].asFloat,
                    \partial4, msg[5].asFloat,
                    \partial5, msg[6].asFloat,
                    \partial6, msg[7].asFloat,
                    \partial7, msg[8].asFloat
                );
            });
        });
    }

    free {
        voiceSynths.do({ arg s; if(s.notNil, { s.free }) });
        fx1Synth.free;
        fx2Synth.free;
        fx3Synth.free;
        duckSynth.free;
        duckEnvSynth.free;
        fxBus.free;
        duckBus.free;
    }
}
