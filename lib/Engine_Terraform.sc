// Engine_Terraform
// Percussion synthesizer combining:
//   UDO DMNO:     hybrid oscillators, binaural stereo, multi-mode VCF
//   Space Drum:   (sequencer in Lua)
//   Esu Trifecta: 3-slot serial FX chain with clock sync + ducking
//   Nymira:       FM partials, subtractive, noise/filtered synthesis
//
// 6 percussion voices, each selectable between 3 synthesis modes
// Signal: voice -> fxBus -> fx1 -> fx2 -> fx3 -> duck -> out

Engine_Terraform : CroneEngine {

    var pg;
    var fxGroup;
    var duckGroup;
    var voiceSynths;  // array of 6 active synths
    var fxBus;
    var fx1Synth, fx2Synth, fx3Synth;
    var duckSynth;
    var duckBus;  // control bus for duck envelope

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
            var partials, amps, phases;
            var sigL, sigR;

            // pitch envelope (percussive sweep)
            pitchEnv = EnvGen.kr(
                Env.perc(0.001, pitchDecay, pitchEnvAmt, -8)
            );
            freq = freq * (1 + pitchEnv);

            // FM modulator
            modulator = SinOsc.ar(freq * fmRatio) * fmIndex * freq;

            // 7 partials based on harmonic series (Nymira-style)
            amps = [partial1, partial2, partial3, partial4, partial5, partial6, partial7];
            partials = Array.fill(7, { arg i;
                var ratio = i + 1;
                SinOsc.ar(freq * ratio + modulator, 0, amps[i])
            });
            sig = Mix.new(partials);

            // amp envelope
            env = EnvGen.kr(
                Env.perc(attack, decay, 1, curve),
                doneAction: Done.freeSelf
            );

            // multi-mode filter (DMNO-inspired: 0=LP, 1=HP, 2=BP)
            sig = Select.ar(filterType, [
                RLPF.ar(sig, filterFreq.clip(40, 18000), filterRes.max(0.1)),
                RHPF.ar(sig, filterFreq.clip(40, 18000), filterRes.max(0.1)),
                BPF.ar(sig, filterFreq.clip(40, 18000), filterRes.max(0.1)) * 2
            ]);

            sig = sig * env * amp;

            // binaural stereo (DMNO-inspired de-phasing)
            sigL = DelayN.ar(sig, 0.01, spread * 0.005);
            sigR = DelayN.ar(sig, 0.01, spread * 0.003 + (detune * 0.001));
            sig = Pan2.ar(sig, pan) + [sigL * (1 - pan.abs) * spread * 0.3, sigR * (1 - pan.abs) * spread * 0.3];

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

            // pitch envelope
            pitchEnv = EnvGen.kr(
                Env.perc(0.001, pitchDecay, pitchEnvAmt, -8)
            );
            freq = freq * (1 + pitchEnv);

            // oscillator shape: 0=sine, 0.33=tri, 0.66=saw, 1=pulse
            osc = SelectX.ar(shape * 3, [
                SinOsc.ar(freq + (detune * 0.5)),
                LFTri.ar(freq + (detune * 0.5)),
                LFSaw.ar(freq + (detune * 0.5)),
                Pulse.ar(freq + (detune * 0.5), pulseWidth)
            ]);

            // noise layer (transient)
            noise = WhiteNoise.ar * EnvGen.kr(Env.perc(0.001, noiseDecay, 1, -8));
            sig = osc + (noise * noiseAmt);

            // filter envelope
            filterEnv = EnvGen.kr(
                Env.perc(0.001, filterDecay, filterEnvAmt, -6)
            );

            // multi-mode filter
            sig = Select.ar(filterType, [
                RLPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.1)),
                RHPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.1)),
                BPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.1)) * 2
            ]);

            // amp envelope
            env = EnvGen.kr(
                Env.perc(attack, decay, 1, curve),
                doneAction: Done.freeSelf
            );
            sig = sig * env * amp;

            // binaural stereo
            sigL = DelayN.ar(sig, 0.01, spread * 0.004);
            sigR = DelayN.ar(sig, 0.01, spread * 0.002 + (detune.abs * 0.0005));
            sig = Pan2.ar(sig, pan) + [sigL * (1 - pan.abs) * spread * 0.3, sigR * (1 - pan.abs) * spread * 0.3];

            Out.ar(out, sig);
        }).add;

        // --- Mode 2: Noise/Filtered (textured, granular-inspired hits) ---
        SynthDef(\tf_noise, {
            arg out, freq=200, amp=0.5, pan=0, detune=0,
                noiseType=0, crackle=0.5,
                grainRate=20, grainDur=0.02,
                pitchEnvAmt=0, pitchDecay=0.05,
                attack=0.001, decay=0.3, curve=(-6),
                filterFreq=3000, filterRes=0.8, filterType=0,
                filterEnvAmt=4000, filterDecay=0.08,
                ringFreq=0, ringAmt=0,
                spread=0.3;

            var sig, env, filterEnv, ring;
            var sigL, sigR;

            // noise source: 0=white, 0.5=pink, 1=crackle/dust
            sig = SelectX.ar(noiseType * 2, [
                WhiteNoise.ar,
                PinkNoise.ar,
                Crackle.ar(crackle.linlin(0, 1, 1.0, 2.0)) + Dust.ar(grainRate * 10) * 0.3
            ]);

            // granular gating
            sig = sig * LFPulse.ar(grainRate, 0, grainDur * grainRate);

            // pitched resonance via comb filter (tuned to freq)
            sig = sig + CombL.ar(sig, 0.05, (1/freq.max(20)).min(0.05), 0.05) * 0.5;

            // filter envelope
            filterEnv = EnvGen.kr(
                Env.perc(0.001, filterDecay, filterEnvAmt, -6)
            );

            // multi-mode filter
            sig = Select.ar(filterType, [
                RLPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.05)),
                RHPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.05)),
                BPF.ar(sig, (filterFreq + filterEnv).clip(40, 18000), filterRes.max(0.05)) * 3
            ]);

            // ring modulation (optional harmonic content)
            ring = SinOsc.ar(ringFreq.max(1));
            sig = (sig * (1 - ringAmt)) + (sig * ring * ringAmt);

            // amp envelope
            env = EnvGen.kr(
                Env.perc(attack, decay, 1, curve),
                doneAction: Done.freeSelf
            );
            sig = sig * env * amp;

            // binaural stereo
            sigL = DelayN.ar(sig, 0.01, spread * 0.006);
            sigR = DelayN.ar(sig, 0.01, spread * 0.001);
            sig = Pan2.ar(sig, pan) + [sigL * (1 - pan.abs) * spread * 0.3, sigR * (1 - pan.abs) * spread * 0.3];

            Out.ar(out, sig);
        }).add;


        // ======== FX SYNTHDEFS (Esu's Trifecta-inspired) ========

        // --- FX: Bypass (default) ---
        SynthDef(\tf_fx_bypass, {
            arg bus;
            var sig = In.ar(bus, 2);
            ReplaceOut.ar(bus, sig);
        }).add;

        // --- FX: Delay (clock-syncable tape delay) ---
        SynthDef(\tf_fx_delay, {
            arg bus, time=0.3, feedback=0.4, mix=0.3, color=0.5;
            var sig, wet, fb;
            sig = In.ar(bus, 2);
            fb = LocalIn.ar(2) * feedback;
            fb = LPF.ar(fb, color.linexp(0, 1, 600, 12000));
            fb = fb.tanh;  // warm saturation
            wet = DelayC.ar(sig + fb, 2.0, time.clip(0.001, 2.0));
            LocalOut.ar(wet);
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Reverb/Shimmer ---
        SynthDef(\tf_fx_reverb, {
            arg bus, size=0.7, decayTime=0.5, mix=0.25, shimmer=0;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = FreeVerb2.ar(sig[0], sig[1], 1.0, size, 0.5);
            // shimmer: pitch-shifted feedback into reverb
            wet = wet + (PitchShift.ar(wet, 0.2, 2.0, 0, 0.01) * shimmer * 0.3);
            wet = LPF.ar(wet, 12000);
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Filter Sweep ---
        SynthDef(\tf_fx_filter, {
            arg bus, freq=2000, res=0.5, mix=1.0, lfoRate=0.1;
            var sig, wet, lfo;
            sig = In.ar(bus, 2);
            lfo = SinOsc.kr(lfoRate).range(0.5, 2.0);
            wet = RLPF.ar(sig, (freq * lfo).clip(40, 18000), res.max(0.1));
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Bitcrush ---
        SynthDef(\tf_fx_crush, {
            arg bus, bits=12, rate=44100, mix=0.5, drive=0;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = Decimator.ar(sig, rate, bits);
            wet = (wet * (1 + (drive * 8))).tanh;  // drive into saturation
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Ring Mod ---
        SynthDef(\tf_fx_ring, {
            arg bus, freq=200, depth=0.5, mix=0.5, lfoRate=0;
            var sig, wet, mod;
            sig = In.ar(bus, 2);
            mod = SinOsc.ar(freq + (SinOsc.kr(lfoRate) * freq * 0.1));
            wet = sig * ((1 - depth) + (mod * depth));
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Chorus ---
        SynthDef(\tf_fx_chorus, {
            arg bus, rate=0.5, depth=0.003, mix=0.4, voices=3;
            var sig, wet;
            sig = In.ar(bus, 2);
            wet = Mix.fill(3, { arg i;
                var r = rate * (1 + (i * 0.1));
                var d = depth * (1 + (i * 0.3));
                DelayC.ar(sig, 0.05, SinOsc.kr(r, i * 1.2).range(0.001, d) + 0.003)
            }) / 3;
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix));
        }).add;

        // --- FX: Phaser ---
        SynthDef(\tf_fx_phaser, {
            arg bus, rate=0.3, depth=0.7, mix=0.5, stages=4;
            var sig, wet, mod;
            sig = In.ar(bus, 2);
            mod = SinOsc.kr(rate).range(200, 4000);
            wet = sig;
            4.do({ arg i;
                wet = AllpassN.ar(wet, 0.01, (mod * (i + 1) / 4).reciprocal.clip(0.0001, 0.01), 0);
            });
            ReplaceOut.ar(bus, (sig * (1 - mix)) + (wet * mix * depth));
        }).add;

        // ======== DUCK / SIDECHAIN (Trifecta-inspired) ========
        SynthDef(\tf_duck, {
            arg bus, duckAmt=0, duckDecay=0.15, duckIn;
            var sig, duckEnv;
            sig = In.ar(bus, 2);
            duckEnv = In.kr(duckIn, 1);
            // invert envelope: 1 when no duck, drops to (1-duckAmt) on trigger
            sig = sig * (1 - (duckEnv * duckAmt));
            ReplaceOut.ar(bus, sig);
        }).add;

        // duck trigger (receives trigger from Lua, outputs envelope on control bus)
        SynthDef(\tf_duck_env, {
            arg out, decay=0.15;
            var trig, env;
            trig = \trig.tr(0);
            env = EnvGen.kr(Env.perc(0.001, decay, 1, -4), trig);
            Out.kr(out, env);
        }).add;

        context.server.sync;

        // ======== STARTUP ========

        // duck envelope generator
        Synth(\tf_duck_env, [\out, duckBus, \decay, 0.15], pg);

        // start FX chain (all bypass initially) on context.out_b
        // voices write to fxBus, then we copy fxBus -> out and apply fx in series
        fx1Synth = Synth(\tf_fx_bypass, [\bus, context.out_b], fxGroup);
        fx2Synth = Synth.after(fx1Synth, \tf_fx_bypass, [\bus, context.out_b]);
        fx3Synth = Synth.after(fx2Synth, \tf_fx_bypass, [\bus, context.out_b]);

        // duck synth at end of chain
        duckSynth = Synth(\tf_duck, [\bus, context.out_b, \duckAmt, 0, \duckIn, duckBus], duckGroup);

        // bus routing synth: copy fxBus to output
        SynthDef(\tf_bus_copy, {
            arg in, out;
            var sig = In.ar(in, 2);
            Out.ar(out, sig);
        }).add;

        context.server.sync;

        Synth(\tf_bus_copy, [\in, fxBus, \out, context.out_b], fxGroup, \addBefore);

        // ======== COMMANDS ========

        // --- Voice trigger (mode 0=FM, 1=Sub, 2=Noise) ---
        this.addCommand("trig", "iifff", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var mode = msg[2].asInteger.clip(0, 2);
            var freq = msg[3].asFloat;
            var amp = msg[4].asFloat;
            var pan = msg[5].asFloat;
            var synthName;

            // free previous if still playing
            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].free;
                voiceSynths[voice] = nil;
            });

            synthName = [\tf_fm, \tf_sub, \tf_noise][mode];
            voiceSynths[voice] = Synth(synthName, [
                \out, fxBus, \freq, freq, \amp, amp, \pan, pan
            ], pg);
        });

        // --- Per-voice parameter set ---
        this.addCommand("voice_param", "isf", { arg msg;
            var voice = msg[1].asInteger.clip(0, 5);
            var param = msg[2].asString.asSymbol;
            var val = msg[3].asFloat;
            if(voiceSynths[voice].notNil, {
                voiceSynths[voice].set(param, val);
            });
        });

        // --- Trigger with full params (for per-step variation) ---
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

        // --- Duck trigger ---
        this.addCommand("duck_trig", "", { arg msg;
            // trigger the duck envelope
            pg.set(\trig, 1);
        });

        this.addCommand("duck_amt", "f", { arg msg;
            duckSynth.set(\duckAmt, msg[1].asFloat);
        });
        this.addCommand("duck_decay", "f", { arg msg;
            duckSynth.set(\duckDecay, msg[1].asFloat);
            pg.set(\decay, msg[1].asFloat);
        });

        // --- FX slot assignment ---
        // slot: 0-2, type: 0=bypass, 1=delay, 2=reverb, 3=filter, 4=crush, 5=ring, 6=chorus, 7=phaser
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

        // --- FX parameter ---
        this.addCommand("fx_param", "isf", { arg msg;
            var slot = msg[1].asInteger.clip(0, 2);
            var param = msg[2].asString.asSymbol;
            var val = msg[3].asFloat;
            case
            { slot == 0 } { fx1Synth.set(param, val) }
            { slot == 1 } { fx2Synth.set(param, val) }
            { slot == 2 } { fx3Synth.set(param, val) };
        });

        // --- FM partial levels (for voice tuning) ---
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
        fxBus.free;
        duckBus.free;
    }
}
