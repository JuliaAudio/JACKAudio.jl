module RingBufTests

using BaseTestNext
import JACKAudio: RingBuffer, read_space, write_space

@testset "RingBuffer Tests" begin
    @testset "Construction" begin
        r = RingBuffer(Float64, 8)
        @test isa(r, RingBuffer{Float64})
        @test read_space(r) == 0
        @test write_space(r) == 8
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
    @testset "Single-write overflow" begin
        r = RingBuffer(Int, 8)
        write(r, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        @test read(r, 4) == [3, 4, 5, 6]
    end
end

end # module