module JACKAudioTests

if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end
using JACKAudio

@testset "JACK Tests" begin
    @testset "Opening Client" begin
        client = JackClient("Julia Test")
        port1 = JackSource(client, "TestSource")
        port1 = JackSink(client, "TestSink")
        activate(client)
        close(client)
    end
end

end # module