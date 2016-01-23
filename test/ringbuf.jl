module RingBufTests

using BaseTestNext
import JACKAudio: RingBuffer, read_space, write_space

@testset "RingBuffer Tests" begin
    @testset "Construction" begin
        r = RingBuffer(Float64, 8)
        @test isa(r, RingBuffer{Float64, UInt(8)})
    end
    @testset "Basic read/write" begin
        r = RingBuffer(Int, 8)
        write(r, [1, 2, 3, 4])
        @test read(r, 4) == [1, 2, 3, 4]
        write(r, [1, 2, 3, 4, 5, 6])
        @test read(r, 6) == [1, 2, 3, 4, 5, 6]
    end
    @testset "Writing overflow" begin
        r = RingBuffer(Int, 8)
        write(r, [1, 2, 3, 4])
        write(r, [1, 2, 3, 4, 5, 6])
        @test read(r, 4) == [3, 4, 1, 2]
    end
end

end # module