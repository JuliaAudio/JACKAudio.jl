module JACKAudioTests

if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end
using JACKAudio
using SampleTypes

if "JACKD" in keys(ENV) && ENV["JACKD"] == "1"
    const jackd=1
else
    const jackd=2
end

@testset "JACK Tests" begin
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
    @testset "Read/Write loop" begin
        sourceclient = JACKClient("Source", 1, 0; connect=false)
        sinkclient = JACKClient("Sink", 0, 1; connect=false)
        sink = sinks(sinkclient)[1]
        source = sources(sourceclient)[1]
        # connect them in JACK
        connect(sink, source)
        # TODO use readblock method or blocksize or something
        # TODO: need a connect method to connect the source and sink
        buf = SampleBuf(rand(Float32, 32, 1), samplerate(sourceclient))
        # call the read and write functions to make sure they're compiled before
        # we actually run the test
        write(sink, buf)
        read(source, 32)
        # clear out any audio we've accumulated in the source buffer
        seekavailable(source)
        # synchronize so we know we're running the test at the beginning of the
        # block. It's still not 100% deterministic but hopefully this makes it
        # pass most of the time.
        read(source, 1)
        # skip the rest of the block we received
        seekavailable(source)
        write(sink, buf)
        # this should block now as well because there weren't any more frames
        # to read. In the next process callback JACK should read from the sink
        # and write to the source, sticking the data in readbuf
        readbuf = read(source, 32)
        @test buf == readbuf
        close(sourceclient)
        close(sinkclient)
    end
end

end # module
