@testset "Validate" begin
    import ONNXmutable: modelproto, graphproto
    import ONNXmutable: validate, uniqueoutput, optypedefined, outputused, inputused
    import ONNX: Proto.NodeProto, Proto.ValueInfoProto

    np(ins,outs,op="A") = NodeProto(input=ins, output=outs, op_type=op)
    vip(name,shape=(2,:A)) = ValueInfoProto(name, shape)

    @testset "Duplicate output name" begin
        gp = graphproto()

        push!(gp.node, np(["in"], ["n1"]))
        push!(gp.node, np(["n1"], ["n2"]))
        push!(gp.node, np(["n2"], ["n1", "n3"]))

        mp = modelproto()
        mp.graph = gp
        @test_throws ErrorException uniqueoutput(mp)
        @test_throws ErrorException validate(mp)
        @test_logs (:warn, r"Duplicate output name: n1 found in \n NodeProto.*in.*n1.* \n and \n NodeProto.*n2.*n1.*n3") uniqueoutput(mp, s -> @warn s)
    end

    @testset "No OP specified" begin
        gp = graphproto()

        push!(gp.node, NodeProto(output=["n1"], input=["in"]))
        mp = modelproto()
        mp.graph = gp
        @test_throws ErrorException optypedefined(mp)
        @test_throws ErrorException validate(mp)
        @test_logs (:warn, r"No op_type defined.*in.*n1") optypedefined(mp, s -> @warn s)
    end

    @testset "All outputs not used" begin
        gp = graphproto()

        push!(gp.node, np(["in"], ["n1", "nf1"]))
        push!(gp.node, np(["n1"], ["n2", "nf2"]))
        push!(gp.node, np(["n2"], ["n3"]))
        gp.output = vip.(["n3", "n1"])
        gp.input = vip.(["in", "nf3"])

        mp = modelproto()
        mp.graph = gp
        @test_throws ErrorException outputused(mp)
        @test_throws ErrorException validate(mp)
        @test_logs (:warn, "Found unused outputs: nf1, nf2, nf3") outputused(mp, s -> @warn s)
    end

    @testset "All inputs not used" begin
        gp = graphproto()

        push!(gp.node, np(["in"], ["n1"]))
        push!(gp.node, np(["n1", "nf1"], ["n2"]))
        push!(gp.node, np(["n2"], ["n3"]))
        gp.output = vip.(["n3", "n1", "nf2"])
        gp.input = vip.(["in"])

        mp = modelproto()
        mp.graph = gp
        @test_throws ErrorException inputused(mp)
        @test_throws ErrorException validate(mp)
        @test_logs (:warn, "Found unused inputs: nf1, nf2") inputused(mp, s -> @warn s)
    end
end