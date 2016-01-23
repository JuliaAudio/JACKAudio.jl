"""
This RingBuffer type is a non-blocking fixed-size buffer. In overflow conditions
(writing to an already-full buffer), the old data is overwritten by the new.
"""

type RingBuffer{T, N}
    buf::Vector{T}
    readidx::UInt
    navailable::UInt
    
    RingBuffer() = new(Array(T, N), 1, 0)
end

RingBuffer(T, size) = RingBuffer{T, UInt(nextpow2(size))}()

read_space{T, N}(rb::RingBuffer{T, N}) = rb.navailable

write_space{T, N}(rb::RingBuffer{T, N}) = N - read_space(rb)

"""Read the ringbuffer contents into the given vector `v`. Returns the number
of elements actually read"""
function Base.read!{T, N}(rb::RingBuffer{T, N}, v::Vector{T})
    total = min(length(v), read_space(rb))
    if rb.readidx + total - 1 <= N
        v[1:total] = rb.buf[rb.readidx:(rb.readidx+total-1)]
    else
        partial = N - rb.readidx + 1
        v[1:partial] = rb.buf[rb.readidx:N]
        v[(partial+1):total] = rb.buf[1:(total-partial)]
    end
    
    rb.readidx = wrapidx(rb, rb.readidx + total)
    rb.navailable -= total
    # println("new readidx: $(rb.readidx)")
    # println("new navailable: $(rb.navailable)")
    
    total
end

"""Read at most `n` bytes from the ring buffer, returning the results as a new
Vector{T}"""
function Base.read{T, N}(rb::RingBuffer{T, N}, n)
    size = min(n, read_space(rb))
    v = Array(T, size)
    read!(rb, v)
    
    v
end

"""Write the given vector `v` to the buffer `rb`. If there is not enough space
in the buffer to hold the contents, old data is overwritten by new"""
function Base.write{T, N}(rb::RingBuffer{T, N}, v::Vector{T})
    vlen = length(v)
    if vlen >= N
        # we're totally overwriting the contents of the buffer. Just take
        # the end of the given vector and fill our buffer with it
        rb.readidx = 1
        rb.navailable = N
        rb.buf[1:N] = v[(vlen-N+1):vlen]
    else
        # we're keeping some data
        start = wrapidx(rb, rb.readidx + read_space(rb))
        if start + vlen - 1 <= N
            rb.buf[start:(start+vlen-1)] = v[:]
        else
            rb.buf[start:N] = v[1:(N-start+1)]
            rb.buf[1:(vlen-N+start-1)] = v[(N-start+2):vlen]
        end
        
        if vlen > write_space(rb)
            # we overwrote some data, so bump the read pointer
            rb.readidx = wrapidx(rb, rb.readidx + (vlen - write_space(rb)))
            rb.navailable = N
        else
            rb.navailable += vlen
        end
    end
    # println("new readidx: $(rb.readidx)")
    # println("new navailable: $(rb.navailable)")
        
    nothing
end

wrapidx{T, N}(rb::RingBuffer{T, N}, val::Unsigned) = (val - 1) & (N - 1) + 1