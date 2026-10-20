//! Picks the speech-to-text model for this PC from the tier table in docs/models.md (rule 5).
//!
//! The table has no Windows rows yet, so this uses its desktop rows, written for Linux, whose runtimes all
//! run on Windows: sherpa-onnx on the CPU or CUDA, and whisper.cpp on CUDA or Vulkan. None of it is measured
//! on a Windows PC.

/// What the app reads from the PC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hardware {
    pub ram_gb: u64,
    /// An NVIDIA GPU with a CUDA driver.
    pub cuda: bool,
    /// A hardware DirectX 12 GPU, not the WARP software adapter: what DirectML can run on.
    pub directml: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    /// `sherpa-onnx-offline` with a NeMo transducer: encoder, decoder and joiner `.int8.onnx` plus `tokens.txt`.
    SherpaTransducer,
    /// `sherpa-onnx-offline` with a NeMo CTC model: `model.int8.onnx` plus `tokens.txt`.
    SherpaCtc,
    /// `whisper-cli` from whisper.cpp with one ggml `.bin`.
    Whisper,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Cpu,
    Cuda,
    /// whisper.cpp's GPU backend for AMD, Intel and Qualcomm GPUs on Windows.
    Vulkan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Choice {
    pub engine: Engine,
    /// The file or directory name the model is published under, the same as on Linux.
    pub model: &'static str,
    pub backend: Backend,
}

/// One row of the tier table: its Default and Fallback columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tier {
    pub primary: Choice,
    pub fallback: Option<Choice>,
}

/// Parakeet TDT 0.6B v3 int8, the CPU and CUDA default (3.6 % WER, 177 ms, 1.8 GB peak RSS on the M4 Pro CPU).
pub const PARAKEET_V3: &str = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
/// Parakeet TDT-CTC 110M int8, the CPU fallback for low-end machines.
pub const PARAKEET_110M: &str = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8";
/// Whisper large-v3-turbo q5_0: the default on a non-NVIDIA GPU, and the 99-language fallback on CUDA.
pub const TURBO_Q5: &str = "ggml-large-v3-turbo-q5_0.bin";

const fn pick(engine: Engine, model: &'static str, backend: Backend) -> Choice {
    Choice { engine, model, backend }
}

pub fn choose(hw: &Hardware) -> Tier {
    use Backend::*;
    use Engine::*;
    // A GPU only helps if there is RAM to load the model next to the desktop, as on Linux.
    if hw.ram_gb >= 8 && hw.cuda {
        return Tier {
            primary: pick(SherpaTransducer, PARAKEET_V3, Cuda),
            fallback: Some(pick(Whisper, TURBO_Q5, Cuda)),
        };
    }
    // The table's AMD / Intel GPU row. ponytail: DirectML capability stands in for a Vulkan driver, which
    // current AMD, Intel and Qualcomm Windows drivers ship next to DirectX 12; on a GPU without one whisper.cpp fails
    // to load and the audio crate runs the fallback. Probe vulkan-1.dll instead if that shows up in the field.
    if hw.ram_gb >= 8 && hw.directml {
        return Tier {
            primary: pick(Whisper, TURBO_Q5, Vulkan),
            fallback: Some(pick(SherpaTransducer, PARAKEET_V3, Cpu)),
        };
    }
    // ponytail: the table names the 110M fallback for low-end machines; RAM below 4 GB (v3 peaks at 1.8 GB)
    // stands in for that until it is measured on such a PC, as on Linux.
    if hw.ram_gb >= 4 {
        Tier { primary: pick(SherpaTransducer, PARAKEET_V3, Cpu), fallback: Some(pick(SherpaCtc, PARAKEET_110M, Cpu)) }
    } else {
        Tier { primary: pick(SherpaCtc, PARAKEET_110M, Cpu), fallback: None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Backend::*;
    use Engine::*;

    fn hw(ram_gb: u64, cuda: bool, directml: bool) -> Hardware {
        Hardware { ram_gb, cuda, directml }
    }

    // Rule 5: the model comes from the docs/models.md tier table. Its desktop rows: CPU Parakeet v3 int8
    // (fallback Parakeet 110M), CUDA Parakeet v3 (fallback Whisper turbo), other GPU Whisper turbo q5_0
    // (fallback Parakeet v3 on the CPU). Literal names on purpose: the audio crate downloads these files.
    #[test]
    fn cuda_runs_parakeet_v3_and_beats_directml() {
        // Every NVIDIA GPU is DirectML-capable too; CUDA must win.
        let t = choose(&hw(16, true, true));
        assert_eq!(t.primary, Choice { engine: SherpaTransducer, model: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", backend: Cuda });
        assert_eq!(t.fallback, Some(Choice { engine: Whisper, model: "ggml-large-v3-turbo-q5_0.bin", backend: Cuda }));
    }

    #[test]
    fn directml_gpu_runs_whisper_turbo_with_parakeet_on_the_cpu_behind_it() {
        let t = choose(&hw(16, false, true));
        assert_eq!(t.primary, Choice { engine: Whisper, model: "ggml-large-v3-turbo-q5_0.bin", backend: Vulkan });
        assert_eq!(t.fallback, Some(Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: Cpu }));
    }

    #[test]
    fn gpu_needs_8_gb_of_ram() {
        assert_eq!(choose(&hw(8, true, true)).primary.backend, Cuda);
        assert_eq!(choose(&hw(8, false, true)).primary.backend, Vulkan);
        for h in [hw(7, true, true), hw(7, false, true)] {
            assert_eq!(choose(&h).primary, Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: Cpu }, "{h:?}");
        }
    }

    #[test]
    fn cpu_only_runs_parakeet_v3_never_a_small_whisper() {
        // No CPU row of the table has a Whisper model.
        for h in [hw(64, false, false), hw(16, false, false), hw(8, false, false), hw(4, false, false)] {
            let t = choose(&h);
            assert_eq!(t.primary, Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: Cpu }, "{h:?}");
            assert_eq!(t.fallback, Some(Choice { engine: SherpaCtc, model: "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", backend: Cpu }), "{h:?}");
        }
    }

    #[test]
    fn under_4_gb_runs_parakeet_110m() {
        assert_eq!(choose(&hw(3, false, false)), Tier { primary: Choice { engine: SherpaCtc, model: PARAKEET_110M, backend: Cpu }, fallback: None });
    }
}
