if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end
using JACKAudio

@testset "JACK Tests" begin
    @testset "Opening Client" begin
        client = JackClient()
    end
end
