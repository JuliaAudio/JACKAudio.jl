# JACKAudio

[![Build Status](https://travis-ci.org/JuliaAudio/JACKAudio.jl.svg?branch=master)](https://travis-ci.org/JuliaAudio/JACKAudio.jl)

This package allows Julia software to read and write audio through the [JACK Audio Connection Kit](http://www.jackaudio.org/), a cross-platform, low-latency audio system.

## Prerequisites

To use this package you must have a working JACK installation. For linux this is most likely available through your distribution. On OSX you can download [JACKOSX binaries](http://jackaudio.org/downloads/). JACKAudio.jl is mostly tested with JACK2, but should also work with JACK1. We also recommend that you have some sort of JACK routing tool such as [QjackCtl](http://qjackctl.sourceforge.net/) to configure and start the JACK server and connect your applications to each other. JACKAudio.jl can start up a jack server in the background if there isn't one already running, but does not expose more advanced configuration, so you're better off using a separate tool to manage your JACK server process.

## Terminology

A `JACKClient` represents a connection to the JACK server, and serves as a container for some number of `JACKSource`s and `JACKSink`s. Each `JACKSource` represents a logically-distinct multi-channel stream. It is a "Source" from the perspective of your Julia code, and acts as an input to your `JACKClient`. Likewise `JACKSink` is an output.

In JACK the channels of a `JACKSource` called "out" would be given the names "out_1", and "out_2". As an example, a `JACKClient` implementing a stereo reverb might have a single 2-channel `JACKSource` input, whereas a mono compressor with a side-chain input might have two mono `JACKSource`s. `JACKSource` is a subtype of the `AudioSource` abstract type defined in [SampleTypes.jl](https://github.com/JuliaAudio/SampleTypes.jl).

## Examples

### Instantiation

The default `JACKClient` is named "Julia" and has one stereo input source and one stereo output sink. You can instantiate it like so:

```julia
c = JACKClient()
```

or give it a different name

```julia
c = JACKClient("Verberator2000")
```

You can specify the number of channels for the default source and sink:

```julia
c = JACKClient("QuadIO", 4, 4) # also works without specifying the name
```

The full constructor call allows you to create multiple sources/sinks with different names and channel counts:

```julia
c = JACKClient("Kompressor", [("Input", 1), ("Sidechain", 1)], [("Output", 1)])
```

After wiring up the inputs and outputs in QjackCtl, you would end up with this:

![Kompressor in QjackCtl](http://juliaaudio.github.io/JACKAudio.jl/img/qjackctl-kompressor.png)

### Reading and Writing

You can access the sources and sinks of a `JACKClient` with the `sources` and `sinks` methods:

```julia
c = JACKClient()
source = sources(c)[1]
sink = sinks(c)[1]
```

Interfacing with JACK sources and sinks is best done with SampleBufs, from the `SampleTypes` package, which handles type and samplerate conversions, as well as convenience features like indexing by time. For instance, to read 5 seconds of audio and play it back, you can write:

```julia
buf = read(source, 5s)
write(sink, buf)
```

