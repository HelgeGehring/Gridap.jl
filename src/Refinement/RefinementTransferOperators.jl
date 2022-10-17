"""
Thoughts on this implementation: 

- In order to be able to dispatch on the choice of integration space, we could 
  use a Val{Symbol} as a emplate parameter. For instance 

    struct Myobj{A}
      function Myobj(sym::Symbol)
        A = typeof(Val(sym))
        new{A}()
      end
    end

    and then dispatch mul!() depending on the symbol (:from/:to).

- However, this might be limiting / not general enough. For instance, when we do 
  not have uniform refinement (some cells get refined, other get coarsened) we will
  have an integration space which is a combination of 'from' and 'to'. 
  We could solve this with a third symbol dispatch like :mixed, but it is not very elegant. 

- Another solution would be to always apply 'change_domain' to both the FEFunction and the 
  test FEBasis. This is general since all changes are done in the background. This might be 
  the most elegant option, but is it the most efficient? 
"""

struct RefinementTransferOperator{T,A,B,C} <: AbstractMatrix{T}
  from   ::A
  to     ::B
  caches ::C

  function RefinementTransferOperator(T,from,to,caches)
    A = typeof(from)
    B = typeof(to)
    C = typeof(caches)
    new{T,A,B,C}(from,to,caches)
  end
end

function RefinementTransferOperator(from::FESpace,to::FESpace; qdegree=3)
  @assert isa(from,TrialFESpace)
  @assert isa(to,TrialFESpace)

  Ω_from = get_triangulation(from)
  Ω_to   = get_triangulation(to)
  @assert isa(Ω_from,RefinedTriangulation) || isa(Ω_to,RefinedTriangulation)
  @assert is_change_possible(Ω_from,Ω_to)

  # Choose integration space (finest)
  Ω  = best_target(Ω_from,Ω_to)
  dΩ = Measure(Ω,qdegree)
  U  = (Ω === Ω_from) ? from : to
  V  = U.space
  vh_to = get_fe_basis(to.space)
  vh = change_domain(vh_to,Ω)

  # Prepare system. TODO: Choosing the projection method should be left to the user. 
  sysmat, sysvec = assemble_mass_matrix(Ω_to,to,to.space,qdegree)
  assem  = SparseMatrixAssembler(to,to.space)
  rhs(uh,vh) = ∫(vh⋅uh) * dΩ

  cache = sysmat, sysvec, rhs, assem, Ω, dΩ, U, V, vh
  return RefinementTransferOperator(eltype(sysmat),from,to,cache)
end

# Solves the problem (uh,vh)_to = (uh_from,vh)_Ω for all vh in Vh_to
function LinearAlgebra.mul!(y,A::RefinementTransferOperator,x)
  sysmat, sysvec, rhs, assem, Ω, dΩ, U, V , vh_Ω = A.caches
  Ω_to = get_triangulation(A.to)

  # Bring uh to the integration domain
  uh_from = FEFunction(A.from,x)
  uh_Ω    = change_domain(uh_from,Ω)

  # Assemble rhs vector
  contr   = rhs(uh_Ω,vh_Ω)
  if Ω !== Ω_to
    contr = merge_contr_cells(contr,Ω,Ω_to)
  end
  vecdata = collect_cell_vector(A.to.space,contr)
  assemble_vector_add!(sysvec,assem,vecdata)

  # Solve projection
  IterativeSolvers.cg!(y,sysmat,sysvec)

  return y
end

function Base.size(A::RefinementTransferOperator)
  (num_free_dofs(A.to),num_free_dofs(A.from))
end

function Base.size(A::RefinementTransferOperator,i::Int)
  if i == 1
    return num_free_dofs(A.to)
  elseif i == 2
    return num_free_dofs(A.from)
  else
    return nothing
  end
end

function Base.display(op::RefinementTransferOperator{T,A,B,C}) where {T,A,B,C}
  s = size(op)
  println("$(s[1])x$(s[2])  RefinementTransferOperator{$(T)}")
end

function assemble_mass_matrix(Ω,Uh,Vh,qdegree)
  dΩ = Measure(Ω,qdegree)
  uh_dir = FEFunction(Uh,zero_free_values(Uh),get_dirichlet_dof_values(Uh))
  a(u,v) = ∫(v⋅u)*dΩ
  b(v)   = a(uh_dir,v)

  sysmat = assemble_matrix(a,Uh,Vh)
  sysvec = assemble_vector(b,Vh)
  return sysmat, -sysvec
end