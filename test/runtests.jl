module JACKAudioTests

if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end
using JACKAudio

@testset "JACK Tests" begin
    # the process callback is not part of the public API, but we want to run
    # some tests on it anyways
    # @testset "Process Callback" begin
    #     client = JackClient()
    #     alloc = @allocated JACKAudio.process(UInt32(256), client.ptr)
        # JACKAudio.process(Cint(128), reinterpret(Ptr{JackClient}, pointer_from_objref(client)))
    #     close(client)
    #     @test alloc == 0
    # end
    @testset "Opening Client" begin
        client = JackClient(active=false)
        source = JackSource(client, "TestSource")
        sink = JackSink(client, "TestSink")
        JACKAudio.activate(client)
        write(sink, rand(Float32, 960000) - 0.5)
        sleep(20.0)
        JACKAudio.deactivate(client)
        close(client)
    end
end

end # module

# module JACKAudioScratch
# using JACKAudio
# 
# client = JackClient()
# client = JackClient("Julia", active=false)
# JACKAudio.activate(client)
# pclient = reinterpret(Ptr{JackClient}, pointer_from_objref(client))
# 
# @allocated JACKAudio.process(JACKAudio.NFrames(128), pclient)
# code_llvm(JACKAudio.process, (JACKAudio.NFrames, Ptr{JackClient}))
# # activate(client)
# # source = JackSource(client, "TestSource")
# # sink = JackSink(client, "TestSink")
# # close(client)
# end