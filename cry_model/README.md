# YAMNet

`yamnet/` is YAMNet, Google's sound event classifier, which
`batchCryDetection.py` uses to score each second of a recording for infant
crying. It's a TensorFlow 2 SavedModel trained on AudioSet that scores 521
sound classes, including "Baby cry, infant cry". It's stored here, rather
than downloaded during setup, so the pipeline doesn't depend on a download
link staying up.

| | |
|---|---|
| Source | <https://www.kaggle.com/models/google/yamnet/tensorFlow2/yamnet/1> (formerly <https://tfhub.dev/google/yamnet/1>) |
| Downloaded | October 2026, as `yamnet-tensorflow2-yamnet-v1.tar.gz` (SHA-256 `b80da2a1a56926fb0767205051a200dd7b3beaf3ea1ea126c42a53943996e5e0`) |
| License | Apache 2.0, in `LICENSE` |
| Code and documentation | <https://github.com/tensorflow/models/tree/master/research/audioset/yamnet> |

The files' SHA-256 checksums:

```
672af6e1e34fe15a42d45d70217fd39f97e10aef9b0effbf9b0bf7826fccd462  yamnet/saved_model.pb
d6753f22f173b2a8b1ce78918eaae79bf0a41ca61f4cfe9a1b948c97ff094ddc  yamnet/variables/variables.data-00000-of-00001
0bc2ca10e56e8a71b96a2cad26adbbabff927e9344fbd2df8ae7275ddf76ae1e  yamnet/variables/variables.index
cdf24d193e196d9e95912a2667051ae203e92a2ba09449218ccb40ef787c6df2  yamnet/assets/yamnet_class_map.csv
```

To check them on ACCRE, run `cd ~/lena-whisper/cry_model && sha256sum -c`,
paste the lines above, and press Ctrl+D.
