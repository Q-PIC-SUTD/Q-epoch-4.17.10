! Copyright (C) 2009-2019 University of Warwick
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.

MODULE particles

  USE boundary
  USE partlist
#ifdef PREFETCH
  USE prefetch
#endif
#ifdef BOUND_HARMONIC
  USE evaluator
#endif
  
  IMPLICIT NONE
#ifdef BOUND_HARMONIC
  
  PRIVATE
  
  PUBLIC :: push_particles, f0
#if defined(PHOTONS) || defined(BREMSSTRAHLUNG)
  PUBLIC :: push_photons
#endif !photons

  REAL(num) :: eye(3,3) = reshape(   &
       (/ 1.0_num, 0.0_num, 0.0_num, &
          0.0_num, 1.0_num, 0.0_num, &
          0.0_num, 0.0_num, 1.0_num/), (/3,3/))
#endif !BOUND_HARMONIC

CONTAINS
#ifdef BOUND_HARMONIC
  REAL(num) FUNCTION zero_small(x) 
    REAL(num), INTENT(in) :: x
    zero_small = x
  END FUNCTION zero_small
  PURE FUNCTION Bsq(ibx,iby,ibz)
    REAL(num), INTENT(in) :: ibx, iby, ibz
    REAL(num) Bsq(3,3)
    bsq(1,1) = ibx*ibx
    bsq(1,2) = ibx*iby
    bsq(1,3) = ibx*ibz
    bsq(2,2) = iby*iby
    bsq(2,3) = iby*ibz
    bsq(3,3) = ibz*ibz
    bsq(2,1) = bsq(1,2)
    bsq(3,1) = bsq(1,3)
    bsq(3,2) = bsq(2,3)
  END FUNCTION Bsq
  PURE FUNCTION crossB(ibx,iby,ibz)
    REAL(num), INTENT(in) :: ibx, iby, ibz
    REAL(num) crossB(3,3)
    crossB(1,2) = ibz
    crossB(1,3) =-iby
    crossB(2,3) = ibx
    crossB(2,1) =-ibz
    crossB(3,1) = iby
    crossB(3,2) =-ibx
  END FUNCTION crossB
#endif

    SUBROUTINE push_particles

    ! 2nd order accurate particle pusher using parabolic weighting
    ! on and off the grid. The calculation of J looks rather odd
    ! Since it works by solving d(rho)/dt = div(J) and doing a 1st order
    ! Estimate of rho(t+1.5*dt) rather than calculating J directly
    ! This gives exact charge conservation on the grid

    ! Contains the integer cell position of the particle in x, y, z
    INTEGER :: cell_x1, cell_x2, cell_x3

    ! Xi (space factor see page 38 in manual)
    ! The code now uses gx and hx instead of xi0 and xi1

    ! J from a given particle, can be spread over up to 3 cells in
    ! Each direction due to parabolic weighting. We allocate 4 or 5
    ! Cells because the position of the particle at t = t+1.5dt is not
    ! known until later. This part of the algorithm could probably be
    ! Improved, but at the moment, this is just a straight copy of
    ! The core of the PSC algorithm
    INTEGER, PARAMETER :: sf0 = sf_min, sf1 = sf_max
    REAL(num) :: jxh, jyh, jzh

    ! Properties of the current particle. Copy out of particle arrays for speed
    REAL(num) :: part_x
    REAL(num) :: part_ux, part_uy, part_uz
    REAL(num) :: part_q, part_mc, ipart_mc, part_weight, part_m
#ifdef HC_PUSH
    REAL(num) :: beta_x, beta_y, beta_z, beta2, beta_dot_u, alpha, sigma
#endif

    ! Used for particle probes (to see of probe conditions are satisfied)
#ifndef NO_PARTICLE_PROBES
    REAL(num) :: init_part_x, final_part_x
    TYPE(particle_probe), POINTER :: current_probe
    TYPE(particle), POINTER :: particle_copy
    REAL(num) :: d_init, d_final
    REAL(num) :: probe_energy, part_mc2
#endif

    ! Contains the floating point version of the cell number (never actually
    ! used)
    REAL(num) :: cell_x_r

    ! The fraction of a cell between the particle position and the cell boundary
    REAL(num) :: cell_frac_x

    ! Weighting factors as Eqn 4.77 page 25 of manual
    ! Eqn 4.77 would be written as
    ! F(j-1) * gmx + F(j) * g0x + F(j+1) * gpx
    ! Defined at the particle position
    REAL(num), DIMENSION(sf_min-1:sf_max+1) :: gx

    ! Defined at the particle position - 0.5 grid cell in each direction
    ! This is to deal with the grid stagger
    REAL(num), DIMENSION(sf_min-1:sf_max+1) :: hx

    ! Fields at particle location
    REAL(num) :: ex_part, ey_part, ez_part, bx_part, by_part, bz_part

    ! P+, P- and Tau variables from Boris1970, page27 of manual
    REAL(num) :: uxp, uxm, uyp, uym, uzp, uzm
    REAL(num) :: tau, taux, tauy, tauz, taux2, tauy2, tauz2

    ! charge to mass ratio modified by normalisation
    REAL(num) :: cmratio, ccmratio

    ! Used by J update
    INTEGER :: xmin, xmax
    REAL(num) :: wx, wy

    ! Temporary variables
    REAL(num) :: idx
    REAL(num) :: idtf, idxf
    REAL(num) :: idt, dto2, dtco2
    REAL(num) :: fcx, fcy, fjx, fjy, fjz
    REAL(num) :: root, dtfac, gamma_rel, part_u2
    REAL(num) :: delta_x, part_vy, part_vz
    INTEGER :: ispecies, ix, dcellx, cx
    INTEGER(i8) :: ipart
#ifdef WORK_DONE_INTEGRATED
    REAL(num) :: tmp_x, tmp_y, tmp_z
    REAL(num) :: work_x, work_y, work_z
#endif
#ifndef NO_PARTICLE_PROBES
    LOGICAL :: probes_for_species
    REAL(num) :: gamma_rel_m1
#endif
#ifndef NO_TRACER_PARTICLES
    LOGICAL :: not_zero_current_species
#endif
    ! Particle weighting multiplication factor
#ifdef PARTICLE_SHAPE_BSPLINE3
    REAL(num) :: cf2
    REAL(num), PARAMETER :: fac = (1.0_num / 24.0_num)**c_ndims
#elif  PARTICLE_SHAPE_TOPHAT
    REAL(num), PARAMETER :: fac = 1.0_num
#else
    REAL(num) :: cf2
    REAL(num), PARAMETER :: fac = (0.5_num)**c_ndims
#endif
#ifdef DELTAF_METHOD
    REAL(num) :: weight_back
#endif
#ifdef BOUND_HARMONIC
    REAL(num), DIMENSION(3) :: lomegadto2, lgammadto2
    REAL(num), DIMENSION(3) :: one_p_lg, one_m_lg, upvec
    REAL(num) part_y, part_z
    REAL(num) &
         Bdotprod,     &! B dot B*(1 + dt*gamma/2)
         detLm,        &! det(L_-)
         detLm_m_Bdot, &! determinant without Bdotprod
         lx, ly, lz         ! x, y, z of offset from binding centre
    REAL(num) :: bfield_factor
    REAL(num), DIMENSION(3,3) :: vm2vp, gminv
    !REAL(num), DIMENSION(3,3) :: dumb
    INTEGER j
#endif

    TYPE(particle), POINTER :: current, next

#ifdef PREFETCH
    CALL prefetch_particle(species_list(1)%attached_list%head)
#endif

    jx = 0.0_num
    jy = 0.0_num
    jz = 0.0_num

    gx = 0.0_num

    ! Unvarying multiplication factors

    idx = 1.0_num / dx
    idt = 1.0_num / dt
    dto2 = dt / 2.0_num
    dtco2 = c * dto2
    dtfac = 0.5_num * dt * fac

    idtf = idt * fac
    idxf = idx * fac

    DO ispecies = 1, n_species
      current => species_list(ispecies)%attached_list%head
      IF (species_list(ispecies)%immobile) CYCLE
      IF (species_list(ispecies)%species_type == c_species_id_photon) THEN
#ifdef BREMSSTRAHLUNG
        IF (ispecies == bremsstrahlung_photon_species) THEN
          IF (bremsstrahlung_photon_dynamics) THEN
            CALL push_photons(ispecies)
          ELSE
            CYCLE
          END IF
        END IF
#endif
#ifdef PHOTONS
        IF (photon_dynamics) CALL push_photons(ispecies)
#endif
        CYCLE
      END IF
#ifndef NO_PARTICLE_PROBES
      current_probe => species_list(ispecies)%attached_probes
      probes_for_species = ASSOCIATED(current_probe)
#endif
#ifndef NO_TRACER_PARTICLES
      not_zero_current_species = .NOT. species_list(ispecies)%zero_current
#endif

#ifdef PER_SPECIES_WEIGHT
      part_weight = species_list(ispecies)%weight
      fcx = idtf * part_weight
      fcy = idxf * part_weight
#endif
#ifndef PER_PARTICLE_CHARGE_MASS
      part_q   = species_list(ispecies)%charge
      part_m   = species_list(ispecies)%mass
      part_mc  = c * species_list(ispecies)%mass
      ipart_mc = 1.0_num / part_mc
      cmratio  = part_q * dtfac * ipart_mc
      ccmratio = c * cmratio
#ifndef NO_PARTICLE_PROBES
      part_mc2 = c * part_mc
#endif
#endif
#ifdef BOUND_HARMONIC
      lomegadto2 = species_list(ispecies)%harmonic_omega**2 * dto2 / c
      lgammadto2 = species_list(ispecies)%harmonic_gamma * dto2
      one_p_lg = 1 + lgammadto2
      one_m_lg = 1 - lgammadto2
      detLm_m_Bdot = one_p_lg(1)*one_p_lg(2)*one_p_lg(3)
      bfield_factor = species_list(ispecies)%bfield_sample_factor
      
      gminv = 0.0_num
      gminv(1,1) = one_m_lg(1)*one_p_lg(2)*one_p_lg(3)
      gminv(2,2) = one_p_lg(1)*one_m_lg(2)*one_p_lg(3)
      gminv(3,3) = one_p_lg(1)*one_p_lg(2)*one_m_lg(3)

      !vm2vp = 0.0_num
      !vm2vp(1,1) = one_m_lg(1) / one_p_lg(1)
      !vm2vp(2,2) = one_m_lg(2) / one_p_lg(2)
      !vm2vp(3,3) = one_m_lg(3) / one_p_lg(3)      
#endif

      !DEC$ VECTOR ALWAYS
      DO ipart = 1, species_list(ispecies)%attached_list%count
        next => current%next
#ifdef PREFETCH
        CALL prefetch_particle(next)
#endif
#ifndef PER_SPECIES_WEIGHT
        part_weight = current%weight
        fcx = idtf * part_weight
        fcy = idxf * part_weight
#endif
#ifdef BOUND_HARMONIC
#ifndef NO_PARTICLE_PROBES
        init_part_x = current%part_pos(1)
#endif
#else
#ifndef NO_PARTICLE_PROBES
        init_part_x = current%part_pos
#endif
#endif !BOUND_HARMONIC
#ifdef PER_PARTICLE_CHARGE_MASS
        part_q   = current%charge
        part_m   = current%mass
        part_mc  = c * current%mass
        ipart_mc = 1.0_num / part_mc
        cmratio  = part_q * dtfac * ipart_mc
        ccmratio = c * cmratio
#ifndef NO_PARTICLE_PROBES
        part_mc2 = c * part_mc
#endif
#endif
        ! Copy the particle properties out for speed
#ifdef BOUND_HARMONIC
        part_x  = current%part_pos(1) - x_grid_min_local        
#else
        part_x  = current%part_pos - x_grid_min_local
#endif
        part_ux = current%part_p(1) * ipart_mc
        part_uy = current%part_p(2) * ipart_mc
        part_uz = current%part_p(3) * ipart_mc

        ! Calculate v(t) from p(t)
        ! See PSC manual page (25-27)
        gamma_rel = SQRT(part_ux**2 + part_uy**2 + part_uz**2 + 1.0_num)
        root = dtco2 / gamma_rel

        ! Move particles to half timestep position to first order
        part_x = part_x + part_ux * root
#ifdef BOUND_HARMONIC
        part_y = current%part_pos(2) + part_uy * root
        part_z = current%part_pos(3) + part_uz * root
        
        ! ho_d must also be at half timestep position for stability
        lx = current%part_pos(1) + part_ux*root - current%part_ip(1)
        ly = current%part_pos(2) + part_uy*root - current%part_ip(2)
        lz = current%part_pos(3) + part_uz*root - current%part_ip(3)
#endif

#ifdef WORK_DONE_INTEGRATED
        ! This is the actual total work done by the fields: Results correspond
        ! with the electron's gamma factor
        root = cmratio / gamma_rel

        tmp_x = part_ux * root
        tmp_y = part_uy * root
        tmp_z = part_uz * root
#endif

        ! Grid cell position as a fraction.
#ifdef PARTICLE_SHAPE_TOPHAT
        cell_x_r = part_x * idx - 0.5_num
#else
        cell_x_r = part_x * idx
#endif
        ! Round cell position to nearest cell
        cell_x1 = FLOOR(cell_x_r + 0.5_num)
        ! Calculate fraction of cell between nearest cell boundary and particle
        cell_frac_x = REAL(cell_x1, num) - cell_x_r
        cell_x1 = cell_x1 + 1

        ! Particle weight factors as described in the manual, page25
        ! These weight grid properties onto particles
        ! Also used to weight particle properties onto grid, used later
        ! to calculate J
        ! NOTE: These weights require an additional multiplication factor!
#ifdef PARTICLE_SHAPE_BSPLINE3
#include "bspline3/gx.inc"
#elif  PARTICLE_SHAPE_TOPHAT
#include "tophat/gx.inc"
#else
#include "triangle/gx.inc"
#endif
        ! added
        if (ipart == 1) print "(a,sp,3ES11.3)", 'gx= ', gx(-1), gx(0), gx(1)
        ! end added
        ! Now redo shifted by half a cell due to grid stagger.
        ! Use shifted version for ex in X, ey in Y, ez in Z
        ! And in Y&Z for bx, X&Z for by, X&Y for bz
        cell_x2 = FLOOR(cell_x_r)
        cell_frac_x = REAL(cell_x2, num) - cell_x_r + 0.5_num
        cell_x2 = cell_x2 + 1

        dcellx = 0
        ! NOTE: These weights require an additional multiplication factor!
#ifdef PARTICLE_SHAPE_BSPLINE3
#include "bspline3/hx_dcell.inc"
#elif  PARTICLE_SHAPE_TOPHAT
#include "tophat/hx_dcell.inc"
#else
#include "triangle/hx_dcell.inc"
#endif

        ! These are the electric and magnetic fields interpolated to the
        ! particle position. They have been checked and are correct.
        ! Actually checking this is messy.
#ifdef PARTICLE_SHAPE_BSPLINE3
#include "bspline3/e_part.inc"
#include "bspline3/b_part.inc"
#elif  PARTICLE_SHAPE_TOPHAT
#include "tophat/e_part.inc"
#include "tophat/b_part.inc"
#else
#include "triangle/e_part.inc"
#include "triangle/b_part.inc"
#endif

        ! update particle momenta using weighted fields
        uxm = part_ux + cmratio * ex_part
        uym = part_uy + cmratio * ey_part
        uzm = part_uz + cmratio * ez_part
#ifdef BOUND_HARMONIC
        ! add lorentzian omega terms
        uxm = uxm - lomegadto2(1)*lx
        uym = uym - lomegadto2(2)*ly
        uzm = uzm - lomegadto2(3)*lz
#endif

#ifdef HC_PUSH
        ! Half timestep, then use Higuera-Cary push see
        ! https://aip.scitation.org/doi/10.1063/1.4979989
        gamma_rel = uxm**2 + uym**2 + uzm**2 + 1.0_num
        alpha = 0.5_num * part_q * dt / part_m
        beta_x = alpha * bx_part
        beta_y = alpha * by_part
        beta_z = alpha * bz_part
        beta2 = beta_x**2 + beta_y**2 + beta_z**2
        sigma = gamma_rel - beta2
        beta_dot_u = beta_x * uxm + beta_y * uym + beta_z * uzm
        gamma_rel = sigma + SQRT(sigma**2 + 4.0_num * (beta2 + beta_dot_u**2))
        gamma_rel = SQRT(0.5_num * gamma_rel)
#else
        ! Half timestep, then use Boris1970 rotation, see Birdsall and Langdon
        gamma_rel = SQRT(uxm**2 + uym**2 + uzm**2 + 1.0_num)
#endif
        root = ccmratio / gamma_rel
#ifdef BOUND_HARMONIC
        !print "(a,es11.2)", "multiplying b*_part with ", bfield_factor
        bx_part = bx_part*bfield_factor*root
        by_part = by_part*bfield_factor*root
        bz_part = bz_part*bfield_factor*root

        ! construct v- to v+
        vm2vp = 0
        ! B dot product
        Bdotprod = bx_part*bx_part*one_p_lg(1) &
                 + by_part*by_part*one_p_lg(2) &
                 + bz_part*bz_part*one_p_lg(3)
        ! diagonal        
        vm2vp = gminv - Bdotprod*eye
        ! add cross
        vm2vp = vm2vp + 2.0_num*crossB(&
             bx_part*one_p_lg(1),&
             by_part*one_p_lg(2),&
             bz_part*one_p_lg(3))
        ! add B tensorprod B
        vm2vp = vm2vp + 2.0_num*Bsq(bx_part,by_part,bz_part)
        ! determinant
        detLm = detLm_m_Bdot + Bdotprod
        vm2vp = vm2vp / detLm
        ! obtain v+ by matrix mul
        upvec = matmul(vm2vp, (/uxm,uym,uzm/))
        uxp = upvec(1)
        uyp = upvec(2)
        uzp = upvec(3)
#else

        taux = bx_part * root
        tauy = by_part * root
        tauz = bz_part * root

        taux2 = taux**2
        tauy2 = tauy**2
        tauz2 = tauz**2

        tau = 1.0_num / (1.0_num + taux2 + tauy2 + tauz2)

        uxp = ((1.0_num + taux2 - tauy2 - tauz2) * uxm &
            + 2.0_num * ((taux * tauy + tauz) * uym &
            + (taux * tauz - tauy) * uzm)) * tau
        uyp = ((1.0_num - taux2 + tauy2 - tauz2) * uym &
            + 2.0_num * ((tauy * tauz + taux) * uzm &
            + (tauy * taux - tauz) * uxm)) * tau
        uzp = ((1.0_num - taux2 - tauy2 + tauz2) * uzm &
            + 2.0_num * ((tauz * taux + tauy) * uxm &
            + (tauz * tauy - taux) * uym)) * tau
#endif
        
        ! Rotation over, go to full timestep
        part_ux = uxp + cmratio * ex_part
        part_uy = uyp + cmratio * ey_part
        part_uz = uzp + cmratio * ez_part
#ifdef BOUND_HARMONIC
        ! add lorentzian omega terms
        part_ux = part_ux - lomegadto2(1)*lx
        part_uy = part_uy - lomegadto2(2)*ly
        part_uz = part_uz - lomegadto2(3)*lz
#endif
        
        ! Calculate particle velocity from particle momentum
        part_u2 = part_ux**2 + part_uy**2 + part_uz**2
        gamma_rel = SQRT(part_u2 + 1.0_num)
        root = c / gamma_rel

        delta_x = part_ux * root * dto2
        part_vy = part_uy * root
        part_vz = part_uz * root

        ! Move particles to end of time step at 2nd order accuracy
        part_x = part_x + delta_x

        ! particle has now finished move to end of timestep, so copy back
        ! into particle array
#ifdef BOUND_HARMONIC
        current%part_pos = (/ &
             part_x + x_grid_min_local, &
             part_y + part_uy*root*dto2, &
             part_z + part_uz*root*dto2 /)
#else
        current%part_pos = part_x + x_grid_min_local
#endif
        current%part_p   = part_mc * (/ part_ux, part_uy, part_uz /)

#ifdef WORK_DONE_INTEGRATED
        ! This is the actual total work done by the fields: Results correspond
        ! with the electron's gamma factor
        root = cmratio / gamma_rel

        work_x = ex_part * (tmp_x + part_ux * root)
        work_y = ey_part * (tmp_y + part_uy * root)
        work_z = ez_part * (tmp_z + part_uz * root)

        current%work_x = work_x
        current%work_y = work_y
        current%work_z = work_z
        current%work_x_total = current%work_x_total + work_x
        current%work_y_total = current%work_y_total + work_y
        current%work_z_total = current%work_z_total + work_z
#endif

#ifdef BOUND_HARMONIC
#ifndef NO_PARTICLE_PROBES
        final_part_x = current%part_pos(1)
#endif
#else
#ifndef NO_PARTICLE_PROBES
        final_part_x = current%part_pos
#endif
#endif !BOUND_HARMONIC        
        ! Original code calculates densities of electrons, ions and neutrals
        ! here. This has been removed to reduce memory footprint

        ! If the code is compiled with zero-current particle support then put in
        ! an IF statement so that the current is not calculated for this species
#ifndef NO_TRACER_PARTICLES
        IF (not_zero_current_species) THEN
#endif
          ! Now advance to t+1.5dt to calculate current. This is detailed in
          ! the manual between pages 37 and 41. The version coded up looks
          ! completely different to that in the manual, but is equivalent.
          ! Use t+1.5 dt so that can update J to t+dt at 2nd order
          part_x = part_x + delta_x

          ! Delta-f calcuation: subtract background from
          ! calculated current.
#ifdef DELTAF_METHOD
          weight_back = current%pvol * f0(ispecies, part_mc / c, current%part_p)
          fcx = idtf * (part_weight - weight_back)
          fcy = idxf * (part_weight - weight_back)
#endif

#ifdef PARTICLE_SHAPE_TOPHAT
          cell_x_r = part_x * idx - 0.5_num
#else
          cell_x_r = part_x * idx
#endif
          cell_x3 = FLOOR(cell_x_r + 0.5_num)
          cell_frac_x = REAL(cell_x3, num) - cell_x_r
          cell_x3 = cell_x3 + 1

          hx = 0.0_num

          dcellx = cell_x3 - cell_x1
          ! NOTE: These weights require an additional multiplication factor!
#ifdef PARTICLE_SHAPE_BSPLINE3
#include "bspline3/hx_dcell.inc"
#elif  PARTICLE_SHAPE_TOPHAT
#include "tophat/hx_dcell.inc"
#else
#include "triangle/hx_dcell.inc"
#endif
          ! added
          if (ipart == 1) print "(a,sp,3ES11.3)", 'hx= ', hx(-1), hx(0), hx(1)
          ! end added

          ! Now change Xi1* to be Xi1*-Xi0*. This makes the representation of
          ! the current update much simpler
          hx = hx - gx

          ! Remember that due to CFL condition particle can never cross more
          ! than one gridcell in one timestep

          xmin = sf_min + (dcellx - 1) / 2
          xmax = sf_max + (dcellx + 1) / 2

          fjx = fcx * part_q
          fjy = fcy * part_q * part_vy
          fjz = fcy * part_q * part_vz

          jxh = 0.0_num
          DO ix = xmin, xmax
            cx = cell_x1 + ix

            wx = hx(ix)
            wy = gx(ix) + 0.5_num * hx(ix)

            ! This is the bit that actually solves d(rho)/dt = -div(J)
            jxh = jxh - fjx * wx
            jyh = fjy * wy
            jzh = fjz * wy

            jx(cx) = jx(cx) + jxh
            jy(cx) = jy(cx) + jyh
            jz(cx) = jz(cx) + jzh
          END DO
#ifndef NO_TRACER_PARTICLES
        END IF
#endif
#if !defined(NO_PARTICLE_PROBES) && !defined(NO_IO)
        IF (probes_for_species) THEN
          ! Compare the current particle with the parameters of any probes in
          ! the system. These particles are copied into a separate part of the
          ! output file.

          gamma_rel_m1 = part_u2 / (gamma_rel + 1.0_num)

          current_probe => species_list(ispecies)%attached_probes

          ! Cycle through probes
          DO WHILE(ASSOCIATED(current_probe))
            ! Note that this is the energy of a single REAL particle in the
            ! pseudoparticle, NOT the energy of the pseudoparticle
            probe_energy = gamma_rel_m1 * part_mc2

            ! Unidirectional probe
            IF (probe_energy > current_probe%ek_min) THEN
              IF (probe_energy < current_probe%ek_max) THEN

                d_init  = current_probe%normal &
                    * (current_probe%point - init_part_x)
                d_final = current_probe%normal &
                    * (current_probe%point - final_part_x)
                IF (d_final < 0.0_num .AND. d_init >= 0.0_num) THEN
                  ! this particle is wanted so copy it to the list associated
                  ! with this probe
                  ALLOCATE(particle_copy)
                  particle_copy = current
                  CALL add_particle_to_partlist(&
                      current_probe%sampled_particles, particle_copy)
                  NULLIFY(particle_copy)
                END IF

              END IF
            END IF
            current_probe => current_probe%next
          END DO
        END IF
#endif
        current => next
      END DO
      CALL current_bcs(species=ispecies)
    END DO

    CALL particle_bcs

  END SUBROUTINE push_particles

  ! Background distribution function used for delta-f calculations.
  ! Specialise to a drifting (tri)-Maxwellian to simplify and ensure
  ! zero density/current divergence.
  ! Can effectively switch off deltaf method by setting zero background density.

  FUNCTION f0(ispecies, mass, p)

    INTEGER, INTENT(IN) :: ispecies
    REAL(num), INTENT(IN) :: mass
    REAL(num), DIMENSION(:), INTENT(IN) :: p
    REAL(num) :: f0
    REAL(num) :: Tx, Ty, Tz, driftx, drifty, driftz, density
    REAL(num) :: f0_exponent, norm, two_kb_mass, two_pi_kb_mass3
    TYPE(particle_species), POINTER :: species

    species => species_list(ispecies)

    IF (ABS(species%initial_conditions%density_back) > c_tiny) THEN
       two_kb_mass = 2.0_num * kb * mass
       two_pi_kb_mass3 = (pi * two_kb_mass)**3

       Tx = species%initial_conditions%temp_back(1)
       Ty = species%initial_conditions%temp_back(2)
       Tz = species%initial_conditions%temp_back(3)
       driftx  = species%initial_conditions%drift_back(1)
       drifty  = species%initial_conditions%drift_back(2)
       driftz  = species%initial_conditions%drift_back(3)
       density = species%initial_conditions%density_back
       f0_exponent = ((p(1) - driftx)**2 / Tx &
                    + (p(2) - drifty)**2 / Ty &
                    + (p(3) - driftz)**2 / Tz) / two_kb_mass
       norm = density / SQRT(two_pi_kb_mass3 * Tx * Ty * Tz)
       f0 = norm * EXP(-f0_exponent)
    ELSE
       f0 = 0.0_num
    END IF

  END FUNCTION f0



#if defined(PHOTONS) || defined(BREMSSTRAHLUNG)
  SUBROUTINE push_photons(ispecies)

    ! Very simple photon pusher
    ! Properties of the current particle. Copy out of particle arrays for speed
    REAL(num) :: delta_x
    INTEGER,INTENT(IN) :: ispecies
    TYPE(particle), POINTER :: current

    REAL(num) :: current_energy, dtfac, fac

    ! Used for particle probes (to see of probe conditions are satisfied)
#ifndef NO_PARTICLE_PROBES
    REAL(num) :: init_part_x, final_part_x
    TYPE(particle_probe), POINTER :: current_probe
    TYPE(particle), POINTER :: particle_copy
    REAL(num) :: d_init, d_final
    LOGICAL :: probes_for_species
#endif

#ifndef NO_PARTICLE_PROBES
    current_probe => species_list(ispecies)%attached_probes
    probes_for_species = ASSOCIATED(current_probe)
#endif
    dtfac = dt * c**2

    ! set current to point to head of list
    current => species_list(ispecies)%attached_list%head
    ! loop over photons
    DO WHILE(ASSOCIATED(current))
      ! Note that this is the energy of a single REAL particle in the
      ! pseudoparticle, NOT the energy of the pseudoparticle
      current_energy = current%particle_energy

      fac = dtfac / current_energy
      delta_x = current%part_p(1) * fac
#ifdef BOUND_HARMONIC
#ifndef NO_PARTICLE_PROBES
      init_part_x = current%part_pos(1)
#endif
      current%part_pos(1) = current%part_pos(1) + delta_x
#ifndef NO_PARTICLE_PROBES
      final_part_x = current%part_pos(1)
#endif
#else !BOUND_HARMONIC
#ifndef NO_PARTICLE_PROBES
      init_part_x = current%part_pos
#endif
      current%part_pos = current%part_pos + delta_x
#ifndef NO_PARTICLE_PROBES
      final_part_x = current%part_pos
#endif
#endif !BOUND_HARMONIC
#ifndef NO_PARTICLE_PROBES
      IF (probes_for_species) THEN
        ! Compare the current particle with the parameters of any probes in
        ! the system. These particles are copied into a separate part of the
        ! output file.

        current_probe => species_list(ispecies)%attached_probes

        ! Cycle through probes
        DO WHILE(ASSOCIATED(current_probe))
          ! Unidirectional probe
          IF (current_energy > current_probe%ek_min) THEN
            IF (current_energy < current_probe%ek_max) THEN

              d_init  = current_probe%normal &
                  * (current_probe%point - init_part_x)
              d_final = current_probe%normal &
                  * (current_probe%point - final_part_x)
              IF (d_final < 0.0_num .AND. d_init >= 0.0_num) THEN
                ! this particle is wanted so copy it to the list associated
                ! with this probe
                ALLOCATE(particle_copy)
                particle_copy = current
                CALL add_particle_to_partlist(&
                    current_probe%sampled_particles, particle_copy)
                NULLIFY(particle_copy)
              END IF

            END IF
          END IF
          current_probe => current_probe%next
        END DO
      END IF
#endif

      current => current%next
    END DO

  END SUBROUTINE push_photons
#endif
#ifdef BOUND_HARMONIC
  
  SUBROUTiNE drive_push(ispecies)
    INTEGER,INTENT(IN) :: ispecies
    TYPE(particle), POINTER :: current

    REAL(num) v(3), x(3)
    REAL(num) :: current_energy, dtfac, fac
    TYPE(parameter_pack) :: parameters
    TYPE(particle_species) spec

    ! Used for particle probes (to see of probe conditions are satisfied)
#ifndef NO_PARTICLE_PROBES
    REAL(num) :: init_part_x, final_part_x
    TYPE(particle_probe), POINTER :: current_probe
    TYPE(particle), POINTER :: particle_copy
    REAL(num) :: d_init, d_final
    LOGICAL :: probes_for_species
#endif
    INTEGER i
    
    spec = species_list(ispecies)
    current => spec%attached_list%head
    DO WHILE (ASSOCIATED(current))
      parameters%use_grid_position = .FALSE.
      parameters%pack_pos = current%part_pos
      v = (/ evaluate_with_parameters(spec%drive_function(i), parameters) &
           , i = 1,3 /)
      
      
    END DO
  END SUBROUTiNE drive_push
#endif
  
END MODULE particles
