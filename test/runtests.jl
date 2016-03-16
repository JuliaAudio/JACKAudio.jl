module JACKAudioTests

if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end
using JACKAudio
using SampleTypes

function jackver()
    verlines = readlines(ignorestatus(`jackd --version`))
    println(join(verlines))
    jackd = split(verlines[1])[1]

    jackd == "jackdmp" ? 2 : 1
end

const jackd = jackver()

# GENERAL WARNING: you probably want to run jackd with as large a buffer as
# possible (e.g. 2048) to reduce the chance of nondeterminism caused by the
# jack callback happening when you don't want it to

@testset "JACK Tests" begin
    # we call the read and write functions here to make sure they're precompiled
    c = JACKClient()
    source = sources(c)[1]
    sink = sinks(c)[1]
    buf = read(source, 1)
    read!(source, buf)
    write(sink, buf)
    close(c)

    c = JACKClient(1, 1)
    source = sources(c)[1]
    sink = sinks(c)[1]
    buf = read(source, 1)
    read!(source, buf)
    write(sink, buf)
    # and a 1D buf
    monobuf = SampleBuf(rand(Float32, 32), samplerate(c))
    read!(source, monobuf)
    write(sink, monobuf)
    close(c)

    # the process callback is not part of the public API, but we want to run
    # some tests on it anyways. This seems to segfault on jack1
    println("test 1")
    jackd == 2 && @testset "Process Callback" begin
        client = JACKClient(active=false)
        # note we're caching the client.portptrs access because it seems to
        # cause 16 bytes of allocation
        ptrs = client.portptrs
        # make sure we run it to warm up
        JACKAudio.process(UInt32(256), ptrs)
        alloc = @allocated JACKAudio.process(UInt32(256), ptrs)
        close(client)
        @test alloc == 0
    end
    println("test 2")
    @testset "No-Argument Construction" begin
        c = JACKClient()
        @test c.name == "Julia"
        @test length(sources(c)) == 1
        @test nchannels(sources(c)[1]) == 2
        @test length(sinks(c)) == 1
        @test nchannels(sinks(c)[1]) == 2
        close(c)
    end
    println("test 3")
    @testset "Channel Count Construction" begin
        c = JACKClient(4, 5)
        @test c.name == "Julia"
        @test length(sources(c)) == 1
        @test nchannels(sources(c)[1]) == 4
        @test length(sinks(c)) == 1
        @test nchannels(sinks(c)[1]) == 5
        close(c)
    end
    println("test 4")
    @testset "Name Construction" begin
        c = JACKClient("TestClient")
        @test c.name == "TestClient"
        @test length(sources(c)) == 1
        @test nchannels(sources(c)[1]) == 2
        @test length(sinks(c)) == 1
        @test nchannels(sinks(c)[1]) == 2
        close(c)
    end
    println("test 5")
    @testset "Full Custom Construction" begin
        c = JACKClient("TestClient", [("In1", 2), ("In2", 3)],
                                     [("Out1", 1), ("Out2", 2)])
        @test c.name == "TestClient"
        @test length(sources(c)) == 2
        @test nchannels(sources(c)[1]) == 2
        @test nchannels(sources(c)[2]) == 3
        @test length(sinks(c)) == 2
        @test nchannels(sinks(c)[1]) == 1
        @test nchannels(sinks(c)[2]) == 2
        close(c)
    end
    println("test 6")
    # this test is an example of how finicky it is to do synchronized audio IO
    # using a stream-based read/write API.
    @testset "Short Reading/Writing (less than ringbuffer) works" begin
        sourceclient = JACKClient("Source", 1, 0; connect=false)
        sinkclient = JACKClient("Sink", 0, 1; connect=false)
        sink = sinks(sinkclient)[1]
        source = sources(sourceclient)[1]
        # connect them in JACK
        connect(sink, source)
        buf = SampleBuf(rand(Float32, 32, 1), samplerate(sourceclient))
        readbuf = SampleBuf(Float32, samplerate(sourceclient), size(buf))
        # clear out any audio we've accumulated in the source buffer
        seekavailable(source)
        # synchronize so we know we're running the test at the beginning of the
        # block. It's still not 100% deterministic but hopefully this makes it
        # pass most of the time.
        read(source, 1)
        # skip the rest of the block we received
        seekavailable(source)
        # this won't block because we just write directly into the ringbuf
        write(sink, buf)
        # this should block now as well because there weren't any more frames
        # to read. In the next process callback JACK should read from the sink
        # and write to the source, sticking the data in readbuf
        read!(source, readbuf)
        @test buf == readbuf
        close(sourceclient)
        close(sinkclient)
    end
    println("test 7")

    @testset "Long reading/writing (more than ringbuffer) works" begin
        sourceclient = JACKClient("Source", 1, 0; connect=false)
        sinkclient = JACKClient("Sink", 0, 1; connect=false)
        sink = sinks(sinkclient)[1]
        source = sources(sourceclient)[1]
        connect(sink, source)

        writebuf = SampleBuf(rand(Float32, JACKAudio.RINGBUF_SAMPLES + 32), samplerate(sourceclient))
        readbuf = SampleBuf(Float32, samplerate(sourceclient), size(writebuf))

        seekavailable(source)
        read(source, 1)
        seekavailable(source)
        @sync begin
            @async write(sink, writebuf)
            @async read!(source, readbuf)
        end
        @test readbuf == writebuf
        close(sourceclient)
        close(sinkclient)
    end
    println("test 8")

    @testset "writers get queued" begin
        sourceclient = JACKClient("Source", 1, 0; connect=false)
        sinkclient = JACKClient("Sink", 0, 1; connect=false)
        sink = sinks(sinkclient)[1]
        source = sources(sourceclient)[1]
        connect(sink, source)

        writebuf1 = SampleBuf(rand(Float32, JACKAudio.RINGBUF_SAMPLES * 2 + 32), samplerate(sourceclient))
        writebuf2 = SampleBuf(rand(Float32, JACKAudio.RINGBUF_SAMPLES * 2 + 32), samplerate(sourceclient))
        readbuf = SampleBuf(Float32, samplerate(sourceclient), length(writebuf1) + length(writebuf2))

        seekavailable(source)
        read(source, 1)
        seekavailable(source)
        @sync begin
            @async write(sink, writebuf1)
            @async write(sink, writebuf2)
            @async read!(source, readbuf)
        end
        @test readbuf[1:length(writebuf1)] == writebuf1
        @test readbuf[(length(writebuf1)+1):end] == writebuf2
        close(sourceclient)
        close(sinkclient)
    end

    println("test 9")

    @testset "readers get queued" begin
        sourceclient = JACKClient("Source", 1, 0; connect=false)
        sinkclient = JACKClient("Sink", 0, 1; connect=false)
        sink = sinks(sinkclient)[1]
        source = sources(sourceclient)[1]
        connect(sink, source)

        writebuf1 = SampleBuf(rand(Float32, JACKAudio.RINGBUF_SAMPLES * 2 + 32), samplerate(sourceclient))
        writebuf2 = SampleBuf(rand(Float32, JACKAudio.RINGBUF_SAMPLES * 2 + 32), samplerate(sourceclient))
        readbuf = SampleBuf(Float32, samplerate(sourceclient), length(writebuf1) + length(writebuf2))

        seekavailable(source)
        read(source, 1)
        seekavailable(source)
        @sync begin
            @async write(sink, writebuf1)
            @async write(sink, writebuf2)
            @async read!(source, readbuf)
        end
        @test readbuf[1:length(writebuf1)] == writebuf1
        @test readbuf[(length(writebuf1)+1):end] == writebuf2
        close(sourceclient)
        close(sinkclient)
    end
end

end # module
