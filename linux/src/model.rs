//! Pick the speech-to-text engine, model and backend from the hardware, following the Linux rows
//! of the tier table in docs/models.md.

#[derive(Debug, Clone, PartialEq)]
pub struct Hardware {
    pub ram_gb: u64,
    pub cores: usize,
    pub cuda: bool,
    pub vulkan: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Engine {
    /// `sherpa-onnx-offline` with a NeMo transducer: encoder, decoder and joiner `.int8.onnx`
    /// plus `tokens.txt` in the model directory.
    SherpaTransducer,
    /// `sherpa-onnx-offline` with a NeMo CTC model: `model.int8.onnx` plus `tokens.txt`.
    SherpaCtc,
    /// `whisper-cli` from whisper.cpp with one ggml `.bin`.
    Whisper,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    pub engine: Engine,
    /// File or directory name under `~/.local/share/shepetal/`, as the project publishes it.
    pub model: &'static str,
    pub backend: &'static str,
}

/// Parakeet TDT 0.6B v3 int8, the Linux CPU and CUDA default (3.6 % WER, 177 ms, 1.8 GB peak RSS).
pub const PARAKEET_V3: &str = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8";
/// Parakeet TDT-CTC 110M int8, the CPU fallback for low-end machines.
pub const PARAKEET_110M: &str = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8";
/// Whisper large-v3-turbo q5_0, the Vulkan default.
pub const TURBO_Q5: &str = "ggml-large-v3-turbo-q5_0.bin";

pub fn choose(hw: &Hardware) -> Choice {
    use Engine::*;
    // A GPU only helps if there is RAM to load the model next to the desktop.
    if hw.ram_gb >= 8 && hw.cuda {
        return Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: "cuda" };
    }
    if hw.ram_gb >= 8 && hw.vulkan {
        return Choice { engine: Whisper, model: TURBO_Q5, backend: "vulkan" };
    }
    // ponytail: the table names the 110M fallback for low-end ARM such as a Raspberry Pi; RAM
    // below 4 GB (v3 peaks at 1.8 GB) stands in for that until it is measured on such a machine.
    if hw.ram_gb >= 4 {
        Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: "cpu" }
    } else {
        Choice { engine: SherpaCtc, model: PARAKEET_110M, backend: "cpu" }
    }
}

/// Read the hardware of this machine.
pub fn detect() -> Hardware {
    let kb = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("MemTotal:"))
            .and_then(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok()))
        .unwrap_or(0);
    let vulkan = std::fs::read_dir("/usr/share/vulkan/icd.d")
        .map(|d| d.count() > 0)
        .unwrap_or(false);
    Hardware {
        // MemTotal is a bit under the installed size, so round up.
        ram_gb: kb.div_ceil(1024 * 1024),
        cores: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        cuda: std::path::Path::new("/dev/nvidia0").exists(),
        vulkan,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Engine::*;

    fn hw(ram_gb: u64, cores: usize, cuda: bool, vulkan: bool) -> Hardware {
        Hardware { ram_gb, cores, cuda, vulkan }
    }

    // Goal rule 5: the model comes from the docs/models.md tier table. Its Linux rows: CPU
    // Parakeet v3 int8 (fallback Parakeet 110M), CUDA Parakeet v3, Vulkan Whisper turbo q5_0.
    #[test]
    fn cuda_runs_parakeet_v3_and_beats_vulkan() {
        assert_eq!(choose(&hw(16, 8, true, true)), Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: "cuda" });
    }

    #[test]
    fn vulkan_runs_whisper_turbo_q5() {
        assert_eq!(choose(&hw(16, 8, false, true)), Choice { engine: Whisper, model: "ggml-large-v3-turbo-q5_0.bin", backend: "vulkan" });
    }

    #[test]
    fn gpu_with_too_little_ram_falls_back_to_cpu() {
        assert_eq!(choose(&hw(7, 4, true, true)), Choice { engine: SherpaTransducer, model: PARAKEET_V3, backend: "cpu" });
    }

    #[test]
    fn cpu_runs_parakeet_v3_never_a_small_whisper() {
        // No Linux CPU row of the table has a Whisper model.
        for h in [hw(32, 16, false, false), hw(16, 8, false, false), hw(8, 2, false, false), hw(4, 4, false, false)] {
            assert_eq!(choose(&h), Choice { engine: SherpaTransducer, model: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", backend: "cpu" }, "{h:?}");
        }
    }

    #[test]
    fn low_end_cpu_falls_back_to_parakeet_110m() {
        assert_eq!(choose(&hw(3, 4, false, false)), Choice { engine: SherpaCtc, model: "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8", backend: "cpu" });
    }
}
