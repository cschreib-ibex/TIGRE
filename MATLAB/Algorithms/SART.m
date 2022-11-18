function [res,errorL2,qualMeasOut]=SART(proj,geo,angles,niter,varargin)
% SART solves Cone Beam CT image reconstruction using Oriented Subsets
%              Simultaneous Algebraic Reconstruction Technique algorithm
%
%   SART(PROJ,GEO,ALPHA,NITER) solves the reconstruction problem
%   using the projection data PROJ taken over ALPHA angles, corresponding
%   to the geometry described in GEO, using NITER iterations.
%
%   SART(PROJ,GEO,ALPHA,NITER,OPT,VAL,...) uses options and values for solving. The
%   possible options in OPT are:
%
%
%   'lambda':      Sets the value of the hyperparameter. Default is 1
%
%   'lambda_red':  Reduction of lambda. Every iteration
%                  lambda=lambdared*lambda. Default is 0.99
%
%   'skipv':       Boolean controlling whether the backprojection weights
%                  are calculated. Default is false (weights are
%                  calculated).
%
%   'exactw':      Boolean controlling whether the forwardprojection weights
%                  are calculated using the exact volume geometry, or an 
%                  extended geometry. Default is false (weights are
%                  calculated using extended geometry).
%
%   'Init':        Describes different initialization techniques.
%                  'none'     : Initializes the image to zeros (default)
%                  'FDK'      : Initializes image to FDK reconstruction
%                  'multigrid': Initializes image by solving the problem in
%                               small scale and increasing it when relative
%                               convergence is reached.
%                  'image'    : Initialization using a user specified
%                               image. Not recommended unless you really
%                               know what you are doing.
%   'InitImg'      an image for the 'image' initialization. Avoid.
%
%   'Verbose'      1 or 0. Default is 1. Gives information about the
%                  progress of the algorithm.
%   'QualMeas'     Asks the algorithm for a set of quality measurement
%                  parameters. Input should contain a cell array of desired
%                  quality measurement names. Example: {'CC','RMSE','MSSIM'}
%                  These will be computed in each iteration.
% 'OrderStrategy'  Chooses the subset ordering strategy. Options are
%                  'ordered' : uses them in the input order, but divided
%                  'random'  : orders them randomly
%                  'angularDistance': chooses the next subset with the
%                                     biggest angular distance with the ones used.
% 'redundancy_weighting': true or false. Default is true. Applies data
%                         redundancy weighting to projections in the update step
%                         (relevant for offset detector geometry)
%--------------------------------------------------------------------------
%--------------------------------------------------------------------------
% This file is part of the TIGRE Toolbox
%
% Copyright (c) 2015, University of Bath and
%                     CERN-European Organization for Nuclear Research
%                     All rights reserved.
%
% License:            Open Source under BSD.
%                     See the full license at
%                     https://github.com/CERN/TIGRE/blob/master/LICENSE
%
% Contact:            tigre.toolbox@gmail.com
% Codes:              https://github.com/CERN/TIGRE/
% Coded by:           Ander Biguri
%--------------------------------------------------------------------------

%% Deal with input parameters
blocksize=1;
[lambda,res,lambdared,skipV,exactW,verbose,QualMeasOpts,OrderStrategy,nonneg,gpuids,redundancy_weights]=parse_inputs(proj,geo,angles,varargin);

measurequality=~isempty(QualMeasOpts);
if nargout>1
    computeL2=true;
else
    computeL2=false;
end
errorL2=[];

[alphablocks,orig_index]=order_subsets(angles,blocksize,OrderStrategy);
index_angles=cell2mat(orig_index);
angles_reorder=cell2mat(alphablocks);

% does detector rotation exists?
if ~isfield(geo,'rotDetector')
    geo.rotDetector=[0;0;0];
end
%% Create weighting matrices

% Projection weight, W
W=computeW(geo,angles,gpuids,exactW);

% Back-Projection weight, V
if ~skipV
    V=computeV(geo,angles,alphablocks,orig_index,'gpuids',gpuids);
end

if redundancy_weights
    % Data redundancy weighting, W_r implemented using Wang weighting
    % reference: https://iopscience.iop.org/article/10.1088/1361-6560/ac16bc
    
    num_frames = size(proj,3);
    W_r = redundancy_weighting(geo);
    W_r = repmat(W_r,[1,1,num_frames]);
    % disp('Size of redundancy weighting matrix');
    % disp(size(W_r));
    W = W.*W_r; % include redundancy weighting in W
end

clear A x y dx dz;
%% hyperparameter stuff
nesterov=false;
if ischar(lambda)&&strcmp(lambda,'nesterov')
    nesterov=true;
    lambda=(1+sqrt(1+4))/2;
    gamma=0;
    ynesterov=zeros(size(res),'single');
    ynesterov_prev=ynesterov;
end
%% Iterate
offOrigin=geo.offOrigin;
offDetector=geo.offDetector;
rotDetector=geo.rotDetector;
DSD=geo.DSD;
DSO=geo.DSO;
% TODO : Add options for Stopping criteria
for ii=1:niter
    if (ii==1 && verbose==1);tic;end
    % If quality is going to be measured, then we need to save previous image
    % THIS TAKES MEMORY!
    if measurequality
        res_prev=res;
    end
    
    % reorder angles
    
    for jj=index_angles
        if size(offOrigin,2)==size(angles,2)
            geo.offOrigin=offOrigin(:,jj);
        end
        if size(offDetector,2)==size(angles,2)
            geo.offDetector=offDetector(:,jj);
        end
        if size(rotDetector,2)==size(angles,2)
            geo.rotDetector=rotDetector(:,jj);
        end
        if size(DSD,2)==size(angles,2)
            geo.DSD=DSD(jj);
        end
        if size(DSO,2)==size(angles,2)
            geo.DSO=DSO(jj);
        end
        % --------- Memory expensive-----------
        
        %         proj_err=proj(:,:,jj)-Ax(res,geo,angles(jj));       %                                 (b-Ax)
        %         weighted_err=W(:,:,jj).*proj_err;                   %                          W^-1 * (b-Ax)
        %         backprj=Atb(weighted_err,geo,angles(jj));           %                     At * W^-1 * (b-Ax)
        %         weigth_backprj=bsxfun(@times,1./V(:,:,jj),backprj); %                 V * At * W^-1 * (b-Ax)
        %         res=res+lambda*weigth_backprj;                      % x= x + lambda * V * At * W^-1 * (b-Ax)
        %------------------------------------
        %--------- Memory cheap(er)-----------
        if nesterov
            % The nesterov update is quite similar to the normal update, it
            % just uses this update, plus part of the last one.
            ynesterov=res+ bsxfun(@times,1./V(:,:,jj),Atb(W(:,:,index_angles(:,jj)).*(proj(:,:,index_angles(:,jj))-Ax(res,geo,angles_reorder(:,jj),'gpuids',gpuids)),geo,angles_reorder(:,jj),'gpuids',gpuids));
            res=(1-gamma)*ynesterov+gamma*ynesterov_prev;
        else
            if skipV
                res=res+lambda* Atb(W(:,:,index_angles(:,jj)).*(proj(:,:,index_angles(:,jj))-Ax(res,geo,angles_reorder(:,jj),'gpuids',gpuids)),geo,angles_reorder(:,jj),'unweighted','gpuids',gpuids);
            else
                res=res+lambda* bsxfun(@times,1./V(:,:,jj),Atb(W(:,:,index_angles(:,jj)).*(proj(:,:,index_angles(:,jj))-Ax(res,geo,angles_reorder(:,jj),'gpuids',gpuids)),geo,angles_reorder(:,jj),'gpuids',gpuids));
            end
        end
        if nonneg
            res=max(res,0);
        end
    end
    
    % If quality is being measured
    if measurequality
        % HERE GOES
        qualMeasOut(:,ii)=Measure_Quality(res,res_prev,QualMeasOpts);
    end
    
    if nesterov
        gamma=(1-lambda);
        lambda=(1+sqrt(1+4*lambda^2))/2;
        gamma=gamma/lambda;
    else
        lambda=lambda*lambdared;
    end
    if computeL2 || nesterov
        geo.offOrigin=offOrigin;
        geo.offDetector=offDetector;
        geo.DSD=DSD;
        geo.rotDetector=rotDetector;
        errornow=im3Dnorm(proj-Ax(res,geo,angles,'gpuids',gpuids),'L2'); % Compute error norm2 of b-Ax
        % If the error is not minimized.
        if  ii~=1 && errornow>errorL2(end)
            if verbose
                disp(['Convergence criteria met, exiting on iteration number:', num2str(ii)]);
            end
            return
        end
        errorL2=[errorL2 errornow];
    end
    
    if (ii==1 && verbose==1)
        expected_time=toc*niter;
        disp('SART');
        disp(['Expected duration   :    ',secs2hms(expected_time)]);
        disp(['Expected finish time:    ',datestr(datetime('now')+seconds(expected_time))]);
        disp('');
    end
end





end

function initres=init_multigrid(proj,geo,alpha)

finalsize=geo.nVoxel;
% start with 64
geo.nVoxel=[64;64;64];
geo.dVoxel=geo.sVoxel./geo.nVoxel;
if any(finalsize<geo.nVoxel)
    initres=zeros(finalsize');
    return;
end
niter=100;
initres=zeros(geo.nVoxel');
while ~isequal(geo.nVoxel,finalsize)
    
    
    % solve subsampled grid
    initres=SART(proj,geo,alpha,niter,'Init','image','InitImg',initres,'Verbose',0,'gpuids',gpuids);
    
    % Get new dims.
    geo.nVoxel=geo.nVoxel*2;
    geo.nVoxel(geo.nVoxel>finalsize)=finalsize(geo.nVoxel>finalsize);
    geo.dVoxel=geo.sVoxel./geo.nVoxel;
    % Upsample!
    % (hopefully computer has enough memory............)
    [y, x, z]=ndgrid(linspace(1,size(initres,1),geo.nVoxel(1)),...
        linspace(1,size(initres,2),geo.nVoxel(2)),...
        linspace(1,size(initres,3),geo.nVoxel(3)));
    initres=interp3(initres,x,y,z);
    clear x y z
end
end


function [lambda,res,lambdared,skipv,exactw,verbose,QualMeasOpts,OrderStrategy,nonneg,gpuids,redundancy_weights]=parse_inputs(proj,geo,alpha,argin)
opts={'lambda','init','initimg','verbose','lambda_red','skipv','exactw','qualmeas','orderstrategy','nonneg','gpuids','redundancy_weighting'};
defaults=ones(length(opts),1);
% Check inputs
nVarargs = length(argin);
if mod(nVarargs,2)
    error('TIGRE:SART:InvalidInput','Invalid number of inputs')
end

% check if option has been passed as input
for ii=1:2:nVarargs
    ind=find(ismember(opts,lower(argin{ii})));
    if ~isempty(ind)
        defaults(ind)=0;
    else
        error('TIGRE:SART:InvalidInput',['Optional parameter "' argin{ii} '" does not exist' ]);
    end
end

for ii=1:length(opts)
    opt=opts{ii};
    default=defaults(ii);
    % if one option is not default, then extract value from input
    if default==0
        ind=double.empty(0,1);jj=1;
        while isempty(ind)
            ind=find(isequal(opt,lower(argin{jj})));
            jj=jj+1;
        end
        if isempty(ind)
            error('TIGRE:SART:InvalidInput',['Optional parameter "' argin{jj} '" does not exist' ]);
        end
        val=argin{jj};
    end
    
    switch opt
        % % % % % % % Verbose
        case 'verbose'
            if default
                verbose=1;
            else
                verbose=val;
            end
            if ~is2014bOrNewer
                warning('TIGRE: Verbose mode not available for older versions than MATLAB R2014b');
                verbose=false;
            end
            % % % % % % % hyperparameter, LAMBDA
        case 'lambda'
            if default
                lambda=1;
            elseif ischar(val)&&strcmpi(val,'nesterov')
                lambda='nesterov'; % just for lowercase/uppercase
            elseif length(val)>1 || ~isnumeric(val)
                error('TIGRE:SART:InvalidInput','Invalid lambda')
            else
                lambda=val;
            end
        case 'lambda_red'
            if default
                lambdared=1;
            else
                if length(val)>1 || ~isnumeric(val)
                    error('TIGRE:SART:InvalidInput','Invalid lambda')
                end
                lambdared=val;
            end
        case 'skipv'
            if default
                skipv=false;
            else
                skipv=val;
            end
        case 'exactw'
            if default
                exactw=false;
            else
                exactw=val;
            end
        case 'init'
            res=[];
            if default || strcmp(val,'none')
                res=zeros(geo.nVoxel','single');
                continue
            end
            if strcmp(val,'FDK')
                res=FDK(proj,geo,alpha);
                continue
            end
            if strcmp(val,'multigrid')
                res=init_multigrid(proj,geo,alpha);
                continue
            end
            if strcmp(val,'image')
                initwithimage=1; % it is used (10 lines below)
                continue
            end
            if isempty(res)
                error('TIGRE:SART:InvalidInput','Invalid Init option')
            end
            % % % % % % % ERROR
        case 'initimg'
            if default
                continue
            end
            if exist('initwithimage','var')
                if isequal(size(val),geo.nVoxel')
                    res=single(val);
                else
                    error('TIGRE:SART:InvalidInput','Invalid image for initialization');
                end
            end
        case 'qualmeas'
            if default
                QualMeasOpts={};
            else
                if iscellstr(val)
                    QualMeasOpts=val;
                else
                    error('TIGRE:SART:InvalidInput','Invalid quality measurement parameters');
                end
            end
        case 'orderstrategy'
            if default
                OrderStrategy='random';
            else
                OrderStrategy=val;
            end
        case 'nonneg'
            if default
                nonneg=true;
            else
                nonneg=val;
            end
        case 'gpuids'
            if default
                gpuids = GpuIds();
            else
                gpuids = val;
            end
        case 'redundancy_weighting'
            if default
                redundancy_weights = true;
            else
                redundancy_weights = val;
            end
        otherwise
            error('TIGRE:SART:InvalidInput',['Invalid input name:', num2str(opt),'\n No such option']);
    end
end

end