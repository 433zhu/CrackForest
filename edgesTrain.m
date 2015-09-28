function model = edgesTrain( varargin )
% Train structured edge detector.
%
% For an introductory tutorial please see edgesDemo.m.
%
% USAGE
%  opts = edgesTrain()
%  model = edgesTrain( opts )
%
% INPUTS
%  opts       - parameters (struct or name/value pairs)
%   (1) model parameters:
%   .imWidth    - [32] width of image patches
%   .gtWidth    - [16] width of ground truth patches
%   (2) tree parameters:
%   .nPos       - [5e5] number of positive patches per tree
%   .nNeg       - [5e5] number of negative patches per tree
%   .nImgs      - [inf] maximum number of images to use for training
%   .nTrees     - [8] number of trees in forest to train
%   .fracFtrs   - [1/4] fraction of features to use to train each tree
%   .minCount   - [1] minimum number of data points to allow split
%   .minChild   - [8] minimum number of data points allowed at child nodes
%   .maxDepth   - [64] maximum depth of tree
%   .discretize - ['pca'] options include 'pca' and 'kmeans'
%   .nSamples   - [256] number of samples for clustering structured labels
%   .nClasses   - [2] number of classes (clusters) for binary splits
%   .split      - ['gini'] options include 'gini', 'entropy' and 'twoing'
%   (3) feature parameters:
%   .nOrients   - [4] number of orientations per gradient scale
%   .grdSmooth  - [0] radius for image gradient smoothing (using convTri)
%   .chnSmooth  - [2] radius for reg channel smoothing (using convTri)
%   .simSmooth  - [8] radius for sim channel smoothing (using convTri)
%   .normRad    - [4] gradient normalization radius (see gradientMag)
%   .shrink     - [2] amount to shrink channels
%   .nCells     - [5] number of self similarity cells
%   .rgbd       - [0] 0:RGB, 1:depth, 2:RBG+depth (for NYU data only)
%   (4) detection parameters (can be altered after training):
%   .stride     - [2] stride at which to compute edges
%   .multiscale - [0] if true run multiscale edge detector
%   .sharpen    - [2] sharpening amount (can only decrease after training)
%   .nTreesEval - [4] number of trees to evaluate per location
%   .nThreads   - [4] number of threads for evaluation of trees
%   .nms        - [0] if true apply non-maximum suppression to edges
%   (5) other parameters:
%   .seed       - [1] seed for random stream (for reproducibility)
%   .useParfor  - [0] if true train trees in parallel (memory intensive)
%   .modelDir   - ['models/'] target directory for storing models
%   .modelFnm   - ['model'] model filename
%   .bsdsDir    - ['BSR/BSDS500/data/'] location of BSDS dataset
%
% OUTPUTS
%  model      - trained structured edge detector w the following fields
%   .opts       - input parameters and constants
%   .thrs       - [nNodes x nTrees] threshold corresponding to each fid
%   .fids       - [nNodes x nTrees] feature ids for each node
%   .child      - [nNodes x nTrees] index of child for each node
%   .count      - [nNodes x nTrees] number of data points at each node
%   .depth      - [nNodes x nTrees] depth of each node
%   .eBins      - data structure for storing all node edge maps
%   .eBnds      - data structure for storing all node edge maps
%
% EXAMPLE
%
% See also edgesDemo, edgesChns, edgesDetect, forestTrain
%
% Structured Edge Detection Toolbox      Version 3.01
% Code written by Piotr Dollar, 2014.
% Licensed under the MSR-LA Full Rights License [see license.txt]

% get default parameters
dfs={'imWidth',32, 'gtWidth',16, 'nPos',5e5, 'nNeg',5e5, 'nImgs',inf, ...
  'nTrees',1, 'fracFtrs',1/4, 'minCount',1, 'minChild',8, ...
  'maxDepth',64, 'discretize','pca', 'nSamples',256, 'nClasses',2, ...
  'split','gini', 'nOrients',4, 'grdSmooth',0, 'chnSmooth',2, ...
  'simSmooth',8, 'normRad',4, 'shrink',2, 'nCells',5, 'rgbd',0, ...
  'stride',2, 'multiscale',0, 'sharpen',2, 'nTreesEval',4, ...
  'nThreads',4, 'nms',0, 'seed',1, 'useParfor',0, 'modelDir','models/', ...
  'modelFnm','model', 'bsdsDir','crack image/'};
opts = getPrmDflt(varargin,dfs,1);%Matlab��ʹ��varargin��ʵ�ֲ����ɱ�ĺ���������ʼֵ
if(nargin==0), model=opts; return; end%������������������Ϊ�㣬����

% if forest exists load it and return �������ѵ���õ�ɭ�֣�����
cd(fileparts(mfilename('fullpath')));
forestDir = [opts.modelDir '/forest/'];
forestFn = [forestDir opts.modelFnm];
% if(exist([forestFn '.mat'], 'file'))%ע�͵��ˣ�ԭ��Ӧ����
%   load([forestFn '.mat']); return; end

% compute constants and store in opts
nTrees=opts.nTrees; nCells=opts.nCells; shrink=opts.shrink;
opts.nPos=round(opts.nPos); opts.nNeg=round(opts.nNeg);%�������뵽����
opts.nTreesEval=min(opts.nTreesEval,nTrees);%number of trees to evaluate per location
opts.stride=max(opts.stride,shrink);%����
imWidth=opts.imWidth; gtWidth=opts.gtWidth;%ͼ���Ĵ�С
imWidth=round(max(gtWidth,imWidth)/shrink/2)*shrink*2;
opts.imWidth=imWidth; opts.gtWidth=gtWidth;
nChnsGrad=(opts.nOrients+1)*2; nChnsColor=3;
if(opts.rgbd==1), nChnsColor=1; end%0:RGB, 1:depth, 2:RBG+depth (for NYU data only)
if(opts.rgbd==2), nChnsGrad=nChnsGrad*2; nChnsColor=nChnsColor+1; end
nChns = nChnsGrad+nChnsColor; opts.nChns = nChns;%3 color, 2 magnitude and 8 orientation channels
opts.nChnFtrs = imWidth*imWidth*nChns/shrink/shrink;%candidate feature x������������32*32*13/2/2=3328��
opts.nSimFtrs = (nCells*nCells)*(nCells*nCells-1)/2*nChns;%����C(5*5,2)������
opts.nTotFtrs = opts.nChnFtrs + opts.nSimFtrs; disp(opts);%�ܼ�7228������ %��ʾ����

% generate stream for reproducibility of model�ظ�����
stream=RandStream('mrg32k3a','Seed',opts.seed);

% train nTrees random trees (can be trained with parfor if enough memory)���е�forѭ��
%��parfor��ǰ���������ǣ�ѭ����ÿ�ε������������໥������
if(opts.useParfor), parfor i=1:nTrees, trainTree(opts,stream,i); end%�����м���
else for i=1:nTrees, trainTree(opts,stream,i); end; end

% merge trees and save model��ģ�ʹ�����
model = mergeTrees( opts );
if(~exist(forestDir,'dir')), mkdir(forestDir); end
save([forestFn '.mat'], 'model', '-v7.3');

end

function model = mergeTrees( opts )
% accumulate trees and merge into final model�ϲ���
nTrees=opts.nTrees; gtWidth=opts.gtWidth;
treeFn = [opts.modelDir '/tree/' opts.modelFnm '_tree'];
for i=1:nTrees
  t=load([treeFn int2str2(i,3) '.mat'],'tree'); t=t.tree;%int2str2����ת�ַ���
  %��i����
  if(i==1), trees=t(ones(1,nTrees)); else trees(i)=t; end%���˿�������һ��1*8������
end
nNodes=0; for i=1:nTrees, nNodes=max(nNodes,size(trees(i).fids,1)); end%�ĸ������õ���������࣬Ҳ���ǽ����
% merge all fields of all trees
model.opts=opts; Z=zeros(nNodes,nTrees,'uint32');%��������Ϊuint32��nNodes*nTrees��������
model.thrs=zeros(nNodes,nTrees,'single');
model.fids=Z; model.child=Z; model.count=Z; model.depth=Z;
model.segs=zeros(gtWidth,gtWidth,nNodes,nTrees,'uint8');%ÿ����Ԫ������ground truth���С�£�������Ƕ��٣��������Ƕ���
for i=1:nTrees, tree=trees(i); nNodes1=size(tree.fids,1);%fids��һά����
  model.fids(1:nNodes1,i) = tree.fids;%�Ѱ˿�����ֵ����������Ϊ8ά�������
  model.thrs(1:nNodes1,i) = tree.thrs;
  model.child(1:nNodes1,i) = tree.child;
  model.count(1:nNodes1,i) = tree.count;
  model.depth(1:nNodes1,i) = tree.depth;
  model.segs(:,:,1:nNodes1,i) = tree.hs-1;
end
% remove very small segments (<=5 pixels)
segs=model.segs; nSegs=squeeze(max(max(segs)))+1;%��segs��Ԫ�����ֵ��squeezeɾȥ����ֻ��һ�л�һ�е�ά�ȣ�ʣnNodes��nTrees��ά
parfor i=1:nTrees*nNodes, m=nSegs(i);%һ��һ�б��������Ŀ������ĸ�������2
  if(m==1), continue; end; S=segs(:,:,i); del=0;
  for j=1:m, Sj=(S==j-1); if(nnz(Sj)>5), continue; end%number of nonzero elements in S.
    S(Sj)=median(single(S(convTri(single(Sj),1)>0))); del=1; end%ÿһ�з���һ��ֵ,ΪM���еĴӴ�С���е��м�ֵ. ��һ������������Ԫ�ض���Ϊ�����ȵ�. Extremely fast 2D image convolution with a triangle filter.
  if(del), [~,~,S]=unique(S); S=reshape(S-1,gtWidth,gtWidth);%unique��������ȥ������A���ظ���Ԫ�� %��ָ���ľ���ı���״,����Ԫ�ظ�������
    segs(:,:,i)=S; nSegs(i)=max(S(:))+1; end%S(:)������һ��һ��ƴ����ת����������
end
model.segs=segs; model.nSegs=nSegs;%��ŵ���ÿ��ymap��������ֵ
% store compact representations of sparse binary edge patches
nBnds=opts.sharpen+1; eBins=cell(nTrees*nNodes,nBnds);%sharpening amount
eBnds=zeros(nNodes*nTrees,nBnds);
parfor i=1:nTrees*nNodes
  if(model.child(i) || model.nSegs(i)==1), continue; end %#ok<PFBNS>
  E=gradientMag(single(model.segs(:,:,i)))>.01; E0=0;%gradientMag ����ͼ��ÿ������ݶȷ�ֵ E�ǰ��ݶȴ���1�ĺ͵���0�ļ�¼����(16*16)
  for j=1:nBnds, eBins{i,j}=uint16(find(E & ~E0)'-1); E0=E;% %��¼ÿ��Ҷ�ӵ�ymap�з����index����һ��λ�ã�
    eBnds(i,j)=length(eBins{i,j}); E=convTri(single(E),1)>.01; end%��¼ÿ��Ҷ�ӵ�ymap�з���ĸ��� %����ģ���󣬰Ѵ���0��λ�ü�¼����
end
eBins=eBins'; model.eBins=[eBins{:}]';%eBins��¼��3��ymapͼ�ķ�������
eBnds=eBnds'; model.eBnds=uint32([0; cumsum(eBnds(:))]);%eBnds��¼��3��ymapͼ�ķ��������ĸ�����С
end

function trainTree( opts, stream, treeInd )
% Train a single tree in forest model.

% location of ground truth
trnImgDir = [opts.bsdsDir '/images/train/'];
trnDepDir = [opts.bsdsDir '/depth/train/'];
trnGtDir = [opts.bsdsDir '/groundTruth/train/'];
imgIds=dir(trnImgDir); imgIds=imgIds([imgIds.bytes]>0);%��ʾxxxĿ¼�µ��ļ����ļ��� ��.bytes��ȡ�ļ���С imgIds����Щ�ļ���С>0���ļ�
imgIds={imgIds.name}; ext=imgIds{1}(end-2:end);%cell 1�����ݣ�������С�������������ݣ�ext�Ǻ�׺������jpg��png�ȵ�
nImgs=length(imgIds); for i=1:nImgs, imgIds{i}=imgIds{i}(1:end-4); end%��ѵ����ͼƬ��nImgs

% extract commonly used options
imWidth=opts.imWidth; imRadius=imWidth/2;
gtWidth=opts.gtWidth; gtRadius=gtWidth/2;
nChns=opts.nChns; nTotFtrs=opts.nTotFtrs; rgbd=opts.rgbd;%ͨ����������������ɫ��
nPos=opts.nPos; nNeg=opts.nNeg; shrink=opts.shrink;

% finalize setup
treeDir = [opts.modelDir '/tree/'];
treeFn = [treeDir opts.modelFnm '_tree'];
if(exist([treeFn int2str2(treeInd,3) '.mat'],'file'))
  fprintf('Reusing tree %d of %d\n',treeInd,opts.nTrees); return; end
fprintf('\n-------------------------------------------\n');
fprintf('Training tree %d of %d\n',treeInd,opts.nTrees); tStart=clock;

% set global stream to stream with given substream (will undo at end)
streamOrig = RandStream.getGlobalStream();
set(stream,'Substream',treeInd);%ѵ���ڼ�����
RandStream.setGlobalStream( stream );

% collect positive and negative patches and compute features
fids=sort(randperm(nTotFtrs,round(nTotFtrs*opts.fracFtrs)));%randperm(n)�������һ���������� �������� ����������������*fraction of features to use to train each tree
% p = randperm(n,k) returns a row vector containing k unique integers selected randomly from 1 to n inclusive.
k = nPos+nNeg; nImgs=min(nImgs,opts.nImgs);%��ѵ����ͼƬ��nImgs
ftrs = zeros(k,length(fids),'single');
labels = zeros(gtWidth,gtWidth,k,'uint8'); k = 0;
tid = ticStatus('Collecting data',30,1);% Used to display the progress of a long process.
for i = 1:nImgs%��ÿ����ѵ����ͼƬ
  % get image and compute channels
  gt=load([trnGtDir imgIds{i} '.mat']); gt=gt.groundTruth;%Ground Truth���Ǳ�ǵģ�����ͼƬ
  I=imread([trnImgDir imgIds{i} '.' ext]); siz=size(I);%��ȡԭͼ ����һ�������������������ĵ�һ��Ԫ���Ǿ�����������ڶ���Ԫ���Ǿ����������
  if(rgbd), D=single(imread([trnDepDir imgIds{i} '.png']))/1e4; end%0:RGB, 1:depth, 2:RBG+depth (for NYU data only)
  if(rgbd==1), I=D; elseif(rgbd==2), I=cat(3,single(I)/255,D); end%rgbdĬ����0������������
  p=zeros(1,4); p([2 4])=mod(4-mod(siz(1:2),4),4);%p�ĵڶ����͵��ĸ�Ԫ��
  if(any(p)), I=imPad(I,p,'symmetric'); end%���������Ƿ��з���Ԫ�أ�����У��򷵻�1�����򣬷���0�� ���ͼ���������顣 ͼ���Сͨ��Χ�Ʊ߽���о���������չ��
  [chnsReg,chnsSim] = edgesChns(I,opts);% Compute features for structured edge detection.
  % ����regular output channels��self-similarity output channels��С��ΪΪԭͼ�������ľ���
  % sample positive and negative locations
  nGt=length(gt); xy=[]; k1=0; B=false(siz(1),siz(2));%BΪ��ԭͼ��Сһ��ȫΪ0�ľ���
  B(shrink:shrink:end,shrink:shrink:end)=1;%shrinkΪ2��Bż���е�ż��Ԫ��Ϊ1
  B([1:imRadius end-imRadius:end],:)=0;%imRadiusΪ17����Bǰshrink�к�ĩshrink����Ϊ0
  B(:,[1:imRadius end-imRadius:end])=0;%��Bǰshrink�к�ĩshrink����Ϊ0
  for j=1:nGt%��ÿ��ͼ���ÿ����ע��ground truth
    %M=gt{j}.Boundaries;
    M=gt(j).Boundaries;%�����Լ���ע������ʱ
    M(bwdist(M)<gtRadius)=1;%ÿ��ֵΪ0�����ص㵽��������ص�ľ���
    %ֱ���Ͽ��ѱ�ע�ı�Ե��Χһ������ĵ㶼��Ϊ��Ե����Ե���֡���
    [y,x]=find(M.*B); k2=min(length(y),ceil(nPos/nImgs/nGt));%find�ҵ�����Ԫ�أ������������꣬.*��ʾ������Ԫ����Ԫ����ˣ������������ά��������ͬ��ceilȡ���� %k2��ÿ��ͼ����Ҫ�ɼ������������
    rp=randperm(length(y),k2); y=y(rp); x=x(rp);%��y��x�����ֻ����k2����
    xy=[xy; x y ones(k2,1)*j]; k1=k1+k2; %#ok<AGROW> %������xһ�У�yһ�У�ground truth���һ�У�����xy������
    [y,x]=find(~M.*B); k2=min(length(y),ceil(nNeg/nImgs/nGt));
    rp=randperm(length(y),k2); y=y(rp); x=x(rp);
    xy=[xy; x y ones(k2,1)*j]; k1=k1+k2; %#ok<AGROW>%������x�͸�����xһ�У�������y�͸�����yһ�У�ground truth���һ�У�����xy������
  end
  if(k1>size(ftrs,1)-k), k1=size(ftrs,1)-k; xy=xy(1:k1,:); end%��֤�������ܸ���
  % crop patches and ground truth labels
  psReg=zeros(imWidth/shrink,imWidth/shrink,nChns,k1,'single');%ÿ���㶼��Ӧ��16*16*13��һ��������k1��������ĸ�����
  lbls=zeros(gtWidth,gtWidth,k1,'uint8');%��ʾ����ͨ����һ�������㡣
  psSim=psReg; ri=imRadius/shrink; rg=gtRadius;
  for j=1:k1, xy1=xy(j,:); xy2=xy1/shrink;%k1Ϊ��������
    psReg(:,:,:,j)=chnsReg(xy2(2)-ri+1:xy2(2)+ri,xy2(1)-ri+1:xy2(1)+ri,:);%��ѡ�����ص��Ӧ������ȡ���������psReg��psSim�� 
    psSim(:,:,:,j)=chnsSim(xy2(2)-ri+1:xy2(2)+ri,xy2(1)-ri+1:xy2(1)+ri,:);
    %t=gt{xy1(3)}.Segmentation(xy1(2)-rg+1:xy1(2)+rg,xy1(1)-rg+1:xy1(1)+rg);
    t=gt(xy1(3)).Segmentation(xy1(2)-rg+1:xy1(2)+rg,xy1(1)-rg+1:xy1(1)+rg);%�����Լ���ע������ʱ %ȡ����ԭʼ�ָ�ͼ��
    if(all(t(:)==t(1))), lbls(:,:,j)=1; else [~,~,t]=unique(t);
      lbls(:,:,j)=reshape(t,gtWidth,gtWidth); end%�Ѿֲ�����ķָ�ͼ�Ž���(16*16)
  end
  if(0), figure(1); montage2(squeeze(psReg(:,:,1,:))); drawnow; end% Used to display collections of images and videos.
  if(0), figure(2); montage2(lbls(:,:,:)); drawnow; end
  % compute features and store
  ftrs1=[reshape(psReg,[],k1)' stComputeSimFtrs(psSim,opts)];%���е��������������������ᵽһ��7228��
  ftrs(k+1:k+k1,:)=ftrs1(:,fids); labels(:,:,k+1:k+k1)=lbls;
  k=k+k1; if(k==size(ftrs,1)), tocStatus(tid,1); break; end
  tocStatus(tid,i/nImgs);
end
if(k<size(ftrs,1)), ftrs=ftrs(1:k,:); labels=labels(:,:,1:k); end

% train structured edge classifier (random decision tree)
pTree=struct('minCount',opts.minCount, 'minChild',opts.minChild, ...
  'maxDepth',opts.maxDepth, 'H',opts.nClasses, 'split',opts.split);
t=labels; labels=cell(k,1); for i=1:k, labels{i}=t(:,:,i); end%��label�������Σ�һ��6000*1��cell��ÿ��cell����16*16 unit8
pTree.discretize=@(hs,H) discretize(hs,H,opts.nSamples,opts.discretize);%ÿ���ڵ㶼��Ҫ��һ��discretize
tree=forestTrain(ftrs,labels,pTree);
tree.hs=cell2array(tree.hs);%dollar toolbox��һ������
tree.fids(tree.child>0) = fids(tree.fids(tree.child>0)+1)-1;
if(~exist(treeDir,'dir')), mkdir(treeDir); end
save([treeFn int2str2(treeInd,3) '.mat'],'tree'); e=etime(clock,tStart);
fprintf('Training of tree %d complete (time=%.1fs).\n',treeInd,e);
RandStream.setGlobalStream( streamOrig );

end

function ftrs = stComputeSimFtrs( chns, opts )
% Compute self-similarity features (order must be compatible w mex file).
w=opts.imWidth/opts.shrink; n=opts.nCells; if(n==0), ftrs=[]; return; end
nSimFtrs=opts.nSimFtrs; nChns=opts.nChns; m=size(chns,4);%chns����ά�ж���ֵ
inds=round(w/n/2); inds=round((1:n)*(w+2*inds-1)/(n+1)-inds+1);
chns=reshape(chns(inds,inds,:,:),n*n,nChns,m);
ftrs=zeros(nSimFtrs/nChns,nChns,m,'single');
k=0; for i=1:n*n-1, k1=n*n-i; i1=ones(1,k1)*i;
  ftrs(k+1:k+k1,:,:)=chns(i1,:,:)-chns((1:k1)+i,:,:); k=k+k1; end%����ftrsֻ��(1:k,:,:)����
ftrs = reshape(ftrs,nSimFtrs,m)';
end

% ----------------------------------------------------------------------- %
% 2015/01/05 cuilimeng
% �Ķ�����discretize��������tmpsegs����
% ----------------------------------------------------------------------- %
function [hs,segs,tmpsegs] = discretize( segs, nClasses, nSamples, type )
% Convert a set of segmentations into a set of labels in [1,nClasses].
tmpsegs=segs;%���ӵ�tmpsegs����
persistent cache;
w=size(segs{1},1); assert(size(segs{1},2)==w);%persistent���徲̬���� %assert ����Ҫ��Բ����ı�������Ҫ�����������������е�һЩ״̬�����жϣ��жϳ����ܷ�/�Ƿ���Ҫ����ִ�С�
if(~isempty(cache) && cache{1}==w), [~,is1,is2]=deal(cache{:}); else %deal(X) �������������ݸ�ֵ�������������
  % compute all possible lookup inds for w x w patches
  is=1:w^4; is1=floor((is-1)/w/w); is2=is-is1*w*w; is1=is1+1;%floor ��ذ巽��ȡ��
  kp=is2>is1; is1=is1(kp); is2=is2(kp); cache={w,is1,is2};%kp��һ����is1��is2һ��������飬ÿλ�ж�is1�Ƿ����is2
end%��ʵ���ֻ�Ǳ�����1~256�䣬һ����������һ��������ϣ�ֻҪ�ļ���ɾ�����������㣻��ʵ����16*16�������������ص�
% compute n binary codes zs of length nSamples
nSamples=min(nSamples,length(is1)); kp=randperm(length(is1),nSamples);%���ȡ256�������ص���ϣ�nSamples��
n=length(segs); is1=is1(kp); is2=is2(kp); zs=false(n,nSamples);%n�ǲ�����ĸ�����zsΪȫlogic 0����
for i=1:n, zs(i,:)=segs{i}(is1)==segs{i}(is2); end%��i������е��������ص���������ͬһ��seg��������1����������0
zs=bsxfun(@minus,zs,sum(zs,1)/n); zs=zs(:,any(zs,1));%nΪ��������ܸ��� %sum(zs,1)������� %sum(zs,1)/n��ÿ��ƽ���ж���������ͬseg����ϣ�һ��double��������sum(zs,1)/n����6000�У���zsȥ�������൱��zs�����ÿ��ֵ��ÿ��ƽ��ֵ��ƫ�� %any���������е�Ԫ���з���Ԫ��ʱ����ֵΪ1��any(A, 1)��ʾ����A���������ж�
if(isempty(zs)), hs=ones(n,1,'uint32'); segs=segs{1}; return; end%û�ã���Դ������
% find most representative segs (closest to mean)
[~,ind]=min(sum(zs.*zs,2)); segs=segs{ind};%zs.*zs��ʾza����ÿ��Ԫ����ƽ����sum(x,2)��ʾ����x�ĺ�����ӣ���ÿ�еĺͣ�������������� %ȡ����ƫ����С���Ǹ�seg��Ҳ����ÿ��Ԫ����ӽ�ƽ��ֵ����seg����д�����
% apply PCA to reduce dimensionality of zs
U=pca(zs'); d=min(5,size(U,2)); zs=zs*U(:,1:d);%��zsת�ã���256(nSample)*6000���㷨��256��ά��5 %�����Ϊzs��ÿ����Ҫά�ȵ�Ȩ��
% discretize zs by clustering or discretizing pca dimensions
d=min(d,floor(log2(nClasses))); hs=zeros(n,1);%����Ҫ����Щ���ַ�Ϊ���࣬d=1��hsΪ6000*1�������
for i=1:d, hs=hs+(zs(:,i)<0)*2^(i-1); end%ÿ�ؼ���zs�ĵ�i�е�С����Ԫ�س���2^(i-1) %����d=1��ֻ��i=1�����ǰ�zs��һάС�����Ԫ�ص�������hs����Ϊ1��Ҳ���ǶԵ�һ�����ɷݸ���ص������㣿��
[~,~,hs]=unique(hs); hs=uint32(hs);%unique(hs)����[0 1]��hs��Ϊԭ��������[0 1]�е�λ�ã���ʵ����һ����ԭ������ȫ��+1�ĸߴ��Ϸ�ʽ���ܽ�ԭ����seg�ֳ�����������������~~
if(strcmpi(type,'kmeans'))
  nClasses1=max(hs); C=zs(1:nClasses1,:);
  for i=1:nClasses1, C(i,:)=mean(zs(hs==i,:),1); end
  hs=uint32(kmeans2(zs,nClasses,'C0',C,'nIter',1));
end
% optionally display different types of hs
%for i=1:2, figure(i); montage2(cell2array(segs(hs==i))); end
%figure(3); imshow(seg);
end
