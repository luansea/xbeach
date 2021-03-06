!==============================================================================
!                               MODULE SOLVER
!==============================================================================

! DATE               AUTHOR               CHANGES
!
! october 2009       Pieter Bart Smit     New module

module solver_module

   implicit none
   save

   ! If mpi is defined, the non-hydrostatic module is NOT included in the compilation
   ! to avoid unwanted side effects.


   !******************************************************************************
   !                                 INTERFACE
   !******************************************************************************

   private

   !----------------------------- PARAMETERS -----------------------------------
   include 'nh_pars.inc'

   !----------------------------- VARIABLES  -----------------------------------

   !--- PRIVATE VARIABLES ---
   logical                  :: initialized = .false.

   integer(kind=iKind)      :: itmea = 0        ! mean number of iterations
   integer(kind=iKind)      :: itmin = 0        ! minimum number of iterations
   integer(kind=iKind)      :: itmax = 0        ! maximum number of iterations
   integer(kind=iKind)      :: ittot = 0        ! total number of iterations
   integer(kind=iKind)      :: itcal = 0        ! total number calls
   integer(kind=iKind)      :: itnconv = 0      ! total number of matrix calls which didn't converge

   real(kind=rKind)         :: reps  = 0.005_rKind
   real(kind=rKind)         :: alpha = 0.94_rKind
   integer(kind=iKind)      :: maxit = 30


   real(kind=rKind),dimension(:,:)  ,allocatable :: residual         ! Residual vector
   real(kind=rKind),dimension(:,:,:),allocatable :: work             ! work matrix

   !--- PUBLIC VARIABLES ---

   !        NONE

   !--- PUBLIC SUBROUTINES ---

   public solver_init      !Allocates resources
   public solver_free      !Free's resources
   public solver_solvemat  !Solve system
   public solver_tridiag
   public solver_sip

   !--- PRIVATE SUBROUTINES

   !        NONE

contains
   !
   !******************************************************************************
   !                             SUBROUTINES/FUNCTIONS
   !******************************************************************************

   !
   !==============================================================================
   subroutine solver_init(nx,ny,par)
      !==============================================================================
      !


      ! DATE               AUTHOR               CHANGES
      !
      ! october 2009       Pieter Bart Smit     New module

      !-------------------------------------------------------------------------------
      !                             DECLARATIONS
      !-------------------------------------------------------------------------------
      !
      !--------------------------        PURPOSE         ----------------------------
      !
      !   Initializes Solver
      !

      !--------------------------     DEPENDENCIES       ----------------------------

      use xmpi_module, only: Halt_Program
      use params
      use logging_module
      use paramsconst

      !--------------------------     ARGUMENTS          ----------------------------
      !
      type(parameters),intent(in) :: par
      integer, intent(in)         :: nx !Number of x-meshes
      integer, intent(in)         :: ny !Number of y-meshes
      !
      !--------------------------     LOCAL VARIABLES    ----------------------------

      !                                - NONE -

      !-------------------------------------------------------------------------------
      !                             IMPLEMENTATION
      !-------------------------------------------------------------------------------
      reps = par%solver_acc
      alpha = par%solver_urelax
      maxit = par%solver_maxit

      ! If sol. met. ok -> allocate resources
      if     (par%solver == SOLVER_SIPP) then   !Solver is SIP
         allocate(    work(5,1:nx+1,1:ny+1)); work     = 0.0_rKind
         allocate(residual(  1:nx+1,1:ny+1)); residual = 0.0_rKind
      elseif (par%solver == SOLVER_TRIDIAGG) then   !Solver is TRI-DIAG, check if possible
         allocate(    work(5,1:nx+1,1:ny+1)); work     = 0.0_rKind
      endif

      initialized = .true.
   end subroutine solver_init





   !
   !==============================================================================
   subroutine solver_free
      !==============================================================================
      !
      if (allocated(residual)) deallocate(residual)
      if (allocated(work))     deallocate(work)

   end subroutine solver_free






   !
   !==============================================================================
   subroutine solver_solvemat( amat  , rhs   , x  , nx, ny, par)
      !==============================================================================
      !

      ! DATE               AUTHOR               CHANGES
      !
      ! october 2009       Pieter Bart Smit     New module

      !-------------------------------------------------------------------------------
      !                             DECLARATIONS
      !-------------------------------------------------------------------------------
      !
      !--------------------------        PURPOSE         ----------------------------
      !
      !   solves matrix
      !

      !--------------------------     DEPENDENCIES       ----------------------------

      use xmpi_module
      use params
      use paramsconst

      !--------------------------     ARGUMENTS          ----------------------------
      !
      integer, intent(in)                                    :: nx    !Number of x-meshes
      integer, intent(in)                                    :: ny    !Number of y-meshes

      real(kind=rKind),dimension(5,nx+1,ny+1)                :: amat !the coefficient matrix used in the linear system
      real(kind=rKind),dimension(nx+1,ny+1)                  :: rhs  !the right-hand side vector of the system of equations
      real(kind=rKind),dimension(nx+1,ny+1)  ,intent(inout)  :: x    !solution of the linear system
      type(parameters),intent(in)                            :: par
      !
      !--------------------------     LOCAL VARIABLES    ----------------------------

      integer(kind=iKind)                                   :: it

      !-------------------------------------------------------------------------------
      !                             IMPLEMENTATION
      !-------------------------------------------------------------------------------

      if (.not. initialized) call solver_init(nx,ny,par)

      if (par%solver == SOLVER_SIPP) then
         !
         itcal = itcal+1        !Number of times the solver procedure is called
         residual = 0.

         call solver_sip  ( amat  , rhs   , x     , residual   , work  , it ,nx, ny) !,reps)

         ittot  = ittot+it      !Total number of iterations
         itmin  = min(it,itmin) !Minimum number of iterations
         itmax  = max(it,itmax) !Maximum number of iterations
         itmea  = ittot/itcal   !Mean number of iterations
         if (it>=par%solver_maxit) then
            itnconv = itnconv+1  !Number of times the solver did not converge
         endif
         !
      elseif (par%solver == SOLVER_TRIDIAGG) then
         !
#ifdef USEMPI
         call xmpi_shift_zs(rhs)
         do it=1,3
            call xmpi_shift_zs(amat(it,:,:))
         enddo
#endif
         call solver_tridiag(amat,rhs,x,work,nx,ny)
#ifdef USEMPI
         call xmpi_shift_zs(x)
#endif
         !
      endif

   end subroutine solver_solvemat

   !
   !==============================================================================
   subroutine solver_tridiag  ( amat  , rhs   , x     ,cmat ,nx ,ny,fixshallow )
      !==============================================================================
      !

      ! DATE               AUTHOR               CHANGES
      !
      ! october 2009       Pieter Bart Smit     New module

      !-------------------------------------------------------------------------------
      !                             DECLARATIONS
      !-------------------------------------------------------------------------------
      !
      !--------------------------        PURPOSE         ----------------------------
      !
      !   Solves matrix use the thomas (or tri-diagonal) algorithm. The solver is only
      !   applicable in the 1-DH case but is substantially faster than the SIP method in
      !   this case
      !
      !   Algorithm is not the most efficient possible as the matrix Amat is still stored
      !   with 5 diagonals and 3 y-points. (Amat(5,s%nx+1,s%ny+1) as opposed to (Amat(3,s%nx+1))
      !   This is easier to incorporate in the more general code.
      !
      !   NOTE: rhs and matrix are not changed.
      !
      !--------------------------     DEPENDENCIES       ----------------------------
      !
      !                                 - NONE -
      !
      !--------------------------     ARGUMENTS          ----------------------------
      !
      integer, intent(in)                                   :: nx   !Number of x-meshes
      integer, intent(in)                                   :: ny   !Number of y-meshes
      logical, intent(in),optional                          :: fixshallow

      real(kind=rKind),dimension(5,nx+1,ny+1),intent(in)    :: amat !the coefficient matrix used in the linear system
      real(kind=rKind),dimension(nx+1,ny+1)  ,intent(in)    :: rhs  !the right-hand side vector of the system of equations
      real(kind=rKind),dimension(nx+1,ny+1)  ,intent(inout) :: x    !solution of the linear system
      real(kind=rKind),dimension(1:nx+1)     ,intent(inout) :: cmat !work vector

      !
      !--------------------------     LOCAL VARIABLES    ----------------------------

      integer(kind=iKind) :: i                                      !Index variable
      integer(kind=iKind) :: jindex                                 !Index variable for superfast1D
      real   (kind=rKind) :: fac                                    !Auxillary variable
      logical             :: lfixshallow

      !-------------------------------------------------------------------------------
      !                             IMPLEMENTATION
      !-------------------------------------------------------------------------------

      if (ny>0) then
         jindex = 2
      else
         jindex = 1
      endif

      if (present(fixshallow)) then
         lfixshallow = fixshallow
      else
         lfixshallow = .false.
      endif

      fac    = amat(1,1,jindex)
      if (abs(fac)<tiny(0.d0) .and. lfixshallow) then
         fac = sign(tiny(0.d0),fac)
      endif
      x(1,jindex) = rhs(1,jindex)/fac

      !forward elimination
      do i=2,nx+1
         cmat(i)  = amat(3,i-1,jindex)/fac
         fac      = amat(1,i,jindex)-amat(2,i,jindex)*cmat(i)
         if (abs(fac)<tiny(0.d0) .and. lfixshallow) then
            fac = sign(tiny(0.d0),fac)
         endif
         x(i,jindex) = (rhs(i,jindex)-amat(2,i,jindex)*x(i-1,jindex))/fac
      enddo

      !Backward substitution
      do i=nx,1,-1
         x(i,jindex) = x(i,jindex)-cmat(i+1)*x(i+1,jindex)
      enddo
   end subroutine solver_tridiag

   !
   !==============================================================================
   subroutine solver_sip  ( amat  , rhs   , x     , res   , cmat  , it ,nx, ny) !, acc)
      !==============================================================================
      !
      !     programmer  Marcel Zijlema
      !
      !     Version 1.0    Date    01-07-2002  HYDRO01: first release
      !     Version 1.1    Date    17-07-2009  Adapted for XBeach (Pieter Smit)
      !
      ! **********************************************************************
      !
      !                       DESCRIPTION
      !
      !     Solves system of equations for the Poisson equation
      !     for one layer by means of Stone's SIP solver
      ! **********************************************************************
      !
      !                       INPUT / OUTPUT ARGUMENTS
      !

      use xmpi_module
      implicit none

      integer(kind=iKind)                    ,intent(out)   :: it   !iteration count
      ! real(kind=rKind)                       ,intent(out)   :: acc  !iteration count
      integer, intent(in)                                   :: nx   !Number of x-meshes
      integer, intent(in)                                   :: ny   !Number of y-meshes

      real(kind=rKind),dimension(5,nx+1,ny+1),intent(in)    :: amat !the coefficient matrix used in the linear system
      real(kind=rKind),dimension(nx+1,ny+1)  ,intent(in)    :: rhs  !the right-hand side vector of the system of equations
      real(kind=rKind),dimension(nx+1,ny+1)  ,intent(inout) :: x    !solution of the linear system
      real(kind=rKind),dimension(5,1:nx+1,1:ny+1),intent(inout) :: cmat !the matrix containing an ILU factorization
      real(kind=rKind),dimension(1:nx+1,1:ny+1)  ,intent(inout) :: res  !the residual vector
      !
      !                       LOCAL VARIABLES
      !
      logical             :: iconv = .false.           ! indicator for convergence
      integer(kind=iKind) :: i                         ! X-direction
      integer(kind=iKind) :: j                         ! Y-direction
      real(kind=rKind)    :: bnorm                     ! 2-norm of right-hand side vector
      real(kind=rKind)    :: epslin                    ! required accuracy in the linear solver
      real(kind=rKind)    :: p1                        ! auxiliary factor
      real(kind=rKind)    :: p2                        ! auxiliary factor
      real(kind=rKind)    :: p3                        ! auxiliary factor
      real(kind=rKind)    :: rnorm                     ! 2-norm of residual vector
      real(kind=rKind)    :: ueps                      ! minimal accuracy based on machine precision
      integer             :: imin,imax,jmin,jmax

      !
      !                       PARAMETERS
      !

      real(kind=rKind),parameter :: small=1.e-15_rKind ! a small number
#ifdef USEMPI
      logical, parameter         :: dompi = .true.     ! use mpi or not use mpi
#endif

      ! **********************************************************************
      !
      !                       I/O
      !
      !     none
      ! **********************************************************************
      !
      !                       SUBROUTINES CALLED
      !
      !
      ! **********************************************************************
      !
      !                       ERROR MESSAGES
      !
      !     none
      ! **********************************************************************
      !
      !                       PSEUDO CODE
      !
      !     The system of equations is solved using an incomplete
      !     factorization technique called Strongly Implicit Procedure
      !     (SIP) as described in
      !
      !     H.L. Stone
      !     Iterative solution of implicit approximations of
      !     multidimensional partial differential equations
      !     SIAM J. of Numer. Anal., vol. 5, 530-558, 1968
      !
      !     This method constructs an incomplete lower-upper factorization
      !     that has the same sparsity as the original matrix. Hereby, a
      !     parameter 0 <= alpha <= 1 is used, which should be around 0.92
      !     (when alpha > 0.95, the method may diverge). Furthermore,
      !     alpha = 0 means standard ILU decomposition.
      !
      !     Afterward, the resulting system is solved in an iterative manner
      !     by forward and backward substitutions.
      ! **********************************************************************
      !

      imin = 2
      imax = nx
      jmin = 2
      jmax = ny
#ifdef USEMPI
      if (dompi) then
         imin = 3
         jmin = 3
         imax = nx-1
         jmax = ny-1

         if (xmpi_istop)   imin = 2
         if (xmpi_isbot)   imax = nx
         if (xmpi_isleft)  jmin = 2
         if (xmpi_isright) jmax = ny
      endif
#endif

      it    = 0
      iconv = .false.

      !     --- construct L and U matrices (stored in cmat)

      bnorm = 0.
      do j = jmin,jmax
         do i = imin,imax
            p1          = alpha*cmat(5,i-1,j)
            p2          = alpha*cmat(3,i,j-1)
            cmat(2,i,j) = amat(2,i,j)/(1.+p1)
            cmat(4,i,j) = amat(4,i,j)/(1.+p2)
            p1 =  p1*cmat(2,i,j)
            p2 =  p2*cmat(4,i,j)
            p3 =  amat(1,i,j) + p1 + p2        &
            - cmat(2,i,j)*cmat(3,i-1,j)    &
            - cmat(4,i,j)*cmat(5,i,j-1)    &
            + small
            cmat(1,i,j) = 1./p3
            cmat(3,i,j) = (amat(3,i,j)-p2)*cmat(1,i,j)
            cmat(5,i,j) = (amat(5,i,j)-p1)*cmat(1,i,j)
            bnorm = bnorm + rhs(i,j)*rhs(i,j)
         enddo
      enddo


#ifdef USEMPI
      if(dompi) then
         call xmpi_allreduce(bnorm,mpi_sum)
      endif
#endif

      bnorm = sqrt(bnorm)

      epslin = reps*bnorm
      ueps   = 1000.*tiny(0.)*bnorm
      if ( epslin < ueps .and. bnorm > 0. ) then
         epslin = ueps
      end if

      !     --- solve the system by forward and backward substitutions
      !         in an iterative manner

      iconv = .false.

      do while ( .not. iconv .and. it < maxit )

         it    = it + 1
         rnorm = 0.

         do j = jmin, jmax
            do i = imin, imax
               res(i,j)  = rhs(i,j)-amat(1,i,j)*x(i,j) &
               -amat(2,i,j)*x(i-1,j)          &
               -amat(3,i,j)*x(i+1,j)          &
               -amat(4,i,j)*x(i,j-1)          &
               -amat(5,i,j)*x(i,j+1)
               !Calculate norm
               rnorm     = rnorm + res(i,j)*res(i,j)
               res(i,j)  = (res(i,j) - cmat(2,i,j)*res(i-1,j)   &
               - cmat(4,i,j)*res(i,j-1))* &
               cmat(1,i,j)
            enddo
         enddo

#ifdef USEMPI
         if (dompi) then
            call xmpi_allreduce(rnorm,mpi_sum)
         endif
#endif

         rnorm=sqrt(rnorm)

         do j = ny, 2, -1
            do i = nx, 2, -1
               res(i,j) = res(i,j) - cmat(3,i,j)*res(i+1,j) - cmat(5,i,j)*res(i,j+1)
               x(i,j)   = x(i,j) + res(i,j)
            enddo
         enddo

#ifdef USEMPI
         if (dompi) then
            call xmpi_shift_zs(x)
         endif
#endif

         iconv = rnorm .lt. epslin

      enddo

   end subroutine solver_sip

end module solver_module
